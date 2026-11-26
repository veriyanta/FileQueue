import Foundation

/// Grouping by ranges: "{size|100MB,1GB}", "{duration|30m}", "{res|720p,1080p}", "{fps|30,60}", and the
/// ready-made "{quality}" (SD / 720p / 1080p / 1440p / 4K). Each range is a folder name like
/// "Under 100 MB", "100 MB – 1 GB", "1 GB or more".
public enum RangeField: String, CaseIterable, Sendable {
    case size, duration, res, fps

    public var label: String {
        switch self {
        case .size: "File size"
        case .duration: "Duration"
        case .res: "Video resolution"
        case .fps: "Frame rate"
        }
    }

    /// Example limits for the UI.
    public var examples: [(title: String, limits: String)] {
        switch self {
        case .size: [("Under 100 MB · 100 MB – 1 GB · 1 GB or more", "100MB,1GB"), ("Under 10 MB · 10 – 100 MB · 100 MB or more", "10MB,100MB"),
                     ("Under 1 GB · 1 – 4 GB · 4 GB or more", "1GB,4GB")]
        case .duration: [("Under 30 min · 30 min or longer", "30m"), ("Under 1 min · 1 – 10 min · 10 min or longer", "1m,10m"),
                         ("Under 10 min · 10 – 30 min · 30 min – 1 h · 1 h or longer", "10m,30m,1h")]
        case .res: [("Under 720p · 720p – 1080p · 1080p or higher", "720p,1080p"), ("Under 1080p · 1080p or higher", "1080p"),
                    ("Under 1080p · 1080p – 4K · 4K or higher", "1080p,4k")]
        case .fps: [("Under 30 fps · 30 – 60 fps · 60 fps or more", "30,60")]
        }
    }

    public var placeholder: String {
        switch self {
        case .size: "e.g. 100MB, 1GB"
        case .duration: "e.g. 30m  or  10m, 1h"
        case .res: "e.g. 720p, 1080p"
        case .fps: "e.g. 30, 60"
        }
    }

    /// Needs the file's contents read (everything except size).
    public var needsDetails: Bool { self != .size }

    var missingLabel: String {
        switch self {
        case .size: "Size"
        case .duration: "Duration"
        case .res: "Resolution"
        case .fps: "Frame rate"
        }
    }

    /// The number this field compares (bytes, seconds, "p", fps), or nil if the file doesn't have it.
    func value(of m: FileMetadata?) -> Double? {
        guard let m else { return nil }
        switch self {
        case .size: return m.size.map(Double.init)
        case .duration: return m.duration.flatMap { $0 > 0 ? $0 : nil }
        case .res: return RangeField.pEquivalent(width: m.width, height: m.height)
        case .fps: return m.fps.flatMap { $0 > 0 ? $0 : nil }
        }
    }

    /// Resolution the way video is labelled: 1280×720 → 720, a 1920×800 widescreen movie → 1080,
    /// portrait 1080×1920 → 1080. (The larger of the short side and the long side × 9/16.)
    public static func pEquivalent(width: Int?, height: Int?) -> Double? {
        guard let w = width, let h = height, w > 0, h > 0 else { return nil }
        let long = Double(max(w, h)), short = Double(min(w, h))
        return max(short, (long * 9 / 16).rounded())
    }

    // MARK: Parsing limits

    /// "100MB,1GB" → [100_000_000, 1_000_000_000] (sorted). nil if any limit can't be read.
    public func parseLimits(_ text: String) -> [Double]? {
        let parts = text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !parts.isEmpty else { return nil }
        var values: [Double] = []
        for part in parts {
            guard let v = parse(part.lowercased().replacingOccurrences(of: " ", with: "")), v > 0 else { return nil }
            values.append(v)
        }
        return Array(Set(values)).sorted()
    }

    private func parse(_ s: String) -> Double? {
        switch self {
        case .size:
            let units: [(String, Double)] = [("tb", 1e12), ("gb", 1e9), ("mb", 1e6), ("kb", 1e3), ("t", 1e12), ("g", 1e9), ("m", 1e6), ("k", 1e3), ("b", 1)]
            for (suffix, factor) in units where s.hasSuffix(suffix) {
                return Double(s.dropLast(suffix.count)).map { $0 * factor }
            }
            return Double(s) // plain bytes
        case .duration:
            // "1h30m", "90s", "45m", "2h"; a plain number means minutes.
            if let plain = Double(s) { return plain * 60 }
            var total = 0.0, number = ""
            for c in s {
                if c.isNumber || c == "." { number.append(c); continue }
                guard let n = Double(number) else { return nil }
                switch c {
                case "h": total += n * 3600
                case "m": total += n * 60
                case "s": total += n
                default: return nil
                }
                number = ""
            }
            return number.isEmpty ? total : nil
        case .res:
            switch s {
            case "4k", "uhd": return 2160
            case "8k": return 4320
            case "2k": return 1440
            case "sd": return 480
            case "hd": return 720
            case "fhd", "fullhd": return 1080
            default: return Double(s.hasSuffix("p") ? String(s.dropLast()) : s)
            }
        case .fps:
            return Double(s.hasSuffix("fps") ? String(s.dropLast(3)) : s)
        }
    }

    // MARK: Naming ranges

    func format(_ v: Double) -> String {
        switch self {
        case .size:
            for (unit, factor) in [("TB", 1e12), ("GB", 1e9), ("MB", 1e6), ("KB", 1e3)] where v >= factor {
                return NameTemplate.trim(v / factor, 1) + " " + unit
            }
            return NameTemplate.trim(v, 0) + " bytes"
        case .duration:
            let total = Int(v.rounded()), h = total / 3600, m = (total % 3600) / 60, s = total % 60
            var parts: [String] = []
            if h > 0 { parts.append("\(h) h") }
            if m > 0 { parts.append("\(m) min") }
            if s > 0 || parts.isEmpty { parts.append("\(s) s") }
            return parts.joined(separator: " ")
        case .res:
            switch Int(v) {
            case 2160: return "4K"
            case 4320: return "8K"
            default: return "\(Int(v))p"
            }
        case .fps:
            return NameTemplate.trim(v, 2) + " fps"
        }
    }

    /// The folder name for `value` given sorted `limits`: "Under A", "A – B", …, "Z or more".
    public func rangeName(for value: Double, limits: [Double]) -> String {
        guard let first = limits.first, let last = limits.last else { return "" }
        if value < first { return "Under \(format(first))" }
        if value >= last {
            switch self {
            case .size: return "\(format(last)) or more"
            case .duration: return "\(format(last)) or longer"
            case .res: return "\(format(last)) or higher"
            case .fps: return "\(format(last)) or more"
            }
        }
        let i = limits.lastIndex { value >= $0 }!
        let lower = limits[i], upper = limits[i + 1]
        if self == .fps { return "\(NameTemplate.trim(lower, 2)) – \(format(upper))" }
        return "\(format(lower)) – \(format(upper))"
    }

    /// All range names for these limits, in order (for previews).
    public func allRangeNames(_ limits: [Double]) -> [String] {
        guard let first = limits.first else { return [] }
        var probes = [first / 2]
        for (i, l) in limits.enumerated() { probes.append(i + 1 < limits.count ? (l + limits[i + 1]) / 2 : l * 2) }
        return probes.map { rangeName(for: $0, limits: limits) }
    }

    /// Standard video quality classes, by the resolution's "p" value.
    public static func quality(_ p: Double) -> String {
        switch p {
        case 2160...: "4K"
        case 1440..<2160: "1440p"
        case 1080..<1440: "1080p"
        case 720..<1080: "720p"
        default: "SD"
        }
    }
}
