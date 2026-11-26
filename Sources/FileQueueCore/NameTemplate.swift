import Foundation

/// Turns a template like "{taken:yyyy-MM-dd HH.mm.ss} {camera}" into a name for one file.
/// Used by the batch-rename Metadata rule and by Organize (where "/" makes subfolders).
public enum NameTemplate {
    public struct Context: Sendable {
        public var metadata: FileMetadata?
        /// The file's name without extension (as it stands at this point in the rule list).
        public var name: String
        public var ext: String
        /// 1-based position (for {n}).
        public var number: Int
        /// Capture groups from a name pattern, for {1}…{9}.
        public var groups: [String]

        public init(metadata: FileMetadata?, name: String, ext: String, number: Int = 1, groups: [String] = []) {
            self.metadata = metadata
            self.name = name
            self.ext = ext
            self.number = number
            self.groups = groups
        }
    }

    public struct Result: Equatable, Sendable {
        public var text: String
        /// Labels of fields the file doesn't have (e.g. ["Date taken"]). Empty when complete.
        public var missing: [String]
    }

    public struct Field: Identifiable, Sendable, Hashable {
        public let token: String
        public let label: String
        public let group: String
        public var id: String { token }
    }

    /// Fields offered in "Insert field" menus.
    public static let fields: [Field] = [
        Field(token: "{taken:yyyy-MM-dd}", label: "Date taken", group: "Dates"),
        Field(token: "{taken:yyyy-MM-dd HH.mm.ss}", label: "Date & time taken", group: "Dates"),
        Field(token: "{taken:yyyy}", label: "Year taken", group: "Dates"),
        Field(token: "{taken:MM}", label: "Month taken", group: "Dates"),
        Field(token: "{created:yyyy-MM-dd}", label: "Date created", group: "Dates"),
        Field(token: "{modified:yyyy-MM-dd}", label: "Date modified", group: "Dates"),
        Field(token: "{date:yyyy-MM-dd}", label: "Date taken, or created if unknown", group: "Dates"),
        Field(token: "{camera}", label: "Camera", group: "Camera"),
        Field(token: "{make}", label: "Camera make", group: "Camera"),
        Field(token: "{model}", label: "Camera model", group: "Camera"),
        Field(token: "{lens}", label: "Lens", group: "Camera"),
        Field(token: "{iso}", label: "ISO", group: "Camera"),
        Field(token: "{aperture}", label: "Aperture (f2.8)", group: "Camera"),
        Field(token: "{focal}", label: "Focal length (24mm)", group: "Camera"),
        Field(token: "{resolution}", label: "Resolution (4000x3000)", group: "Image & video"),
        Field(token: "{width}", label: "Width", group: "Image & video"),
        Field(token: "{height}", label: "Height", group: "Image & video"),
        Field(token: "{duration}", label: "Duration (1m05s)", group: "Image & video"),
        Field(token: "{fps}", label: "Frame rate", group: "Image & video"),
        Field(token: "{codec}", label: "Video codec", group: "Image & video"),
        Field(token: "{title:clean}", label: "Title inside the file, cleaned (Edge of Tomorrow (2014))", group: "Image & video"),
        Field(token: "{title}", label: "Title inside the file, as is", group: "Image & video"),
        Field(token: "{type}", label: "Kind (Photos, Videos…)", group: "File"),
        Field(token: "{quality}", label: "Video quality (SD, 720p, 1080p, 1440p, 4K)", group: "Ranges"),
        Field(token: "{res|720p,1080p}", label: "Resolution: under 720p / 720p – 1080p / 1080p or higher", group: "Ranges"),
        Field(token: "{duration|30m}", label: "Duration: under / over 30 min", group: "Ranges"),
        Field(token: "{size|100MB,1GB}", label: "Size: under 100 MB / 100 MB – 1 GB / 1 GB or more", group: "Ranges"),
        Field(token: "{ext}", label: "Extension", group: "File"),
        Field(token: "{name}", label: "Original name", group: "File"),
        Field(token: "{prefix:3}", label: "First characters of name", group: "File"),
        Field(token: "{n:3}", label: "Counter (001, 002…)", group: "File"),
    ]

    public static func render(_ template: String, _ ctx: Context) -> Result {
        var output = ""
        var missing: [String] = []
        var i = template.startIndex
        while i < template.endIndex {
            let c = template[i]
            if c == "{", let close = template[i...].firstIndex(of: "}") {
                let inner = String(template[template.index(after: i)..<close])
                let (key, arg) = split(inner)
                let result: Value
                if let bar = inner.firstIndex(of: "|") {
                    result = rangeValue(String(inner[..<bar]), String(inner[inner.index(after: bar)...]), ctx)
                } else {
                    result = value(key, arg, ctx)
                }
                switch result {
                case let .text(t): output += sanitize(t)
                case let .missing(label): missing.append(label)
                case .unknown: output += "{" + inner + "}"; missing.append("“{\(inner)}” isn’t a known field")
                }
                i = template.index(after: close)
            } else {
                output.append(c)
                i = template.index(after: i)
            }
        }
        return Result(text: output.trimmingCharacters(in: .whitespaces), missing: missing)
    }

    /// Fields that need the file to be opened (EXIF, video headers); the rest come from the file system.
    static let deepKeys: Set<String> = ["taken", "date", "camera", "make", "model", "lens", "iso", "aperture",
                                         "focal", "resolution", "width", "height", "duration", "fps", "codec", "title",
                                         "res", "quality"]

    /// Does this template need details that are only known after reading the file?
    public static func needsDetails(_ template: String) -> Bool {
        var rest = Substring(template)
        while let open = rest.firstIndex(of: "{"), let close = rest[open...].firstIndex(of: "}") {
            if deepKeys.contains(split(String(rest[rest.index(after: open)..<close])).0) { return true }
            rest = rest[rest.index(after: close)...]
        }
        return false
    }

    /// The fields a template uses, by label (for coverage checks).
    public static func labels(in template: String) -> [String] {
        var labels: [String] = []
        var rest = Substring(template)
        while let open = rest.firstIndex(of: "{"), let close = rest[open...].firstIndex(of: "}") {
            let (key, _) = split(String(rest[rest.index(after: open)..<close]))
            if let l = label(for: key), !labels.contains(l) { labels.append(l) }
            rest = rest[rest.index(after: close)...]
        }
        return labels
    }

    // MARK: Values

    enum Value { case text(String), missing(String), unknown }

    /// "taken:yyyy" → ("taken", "yyyy"); "size|100MB,1GB" → ("size", "100MB,1GB").
    static func split(_ inner: String) -> (String, String?) {
        guard let sep = inner.firstIndex(where: { $0 == ":" || $0 == "|" }) else { return (inner, nil) }
        return (String(inner[..<sep]), String(inner[inner.index(after: sep)...]))
    }

    /// "{size|100MB,1GB}" etc.: the range the file falls in.
    static func rangeValue(_ key: String, _ limitsText: String, _ ctx: Context) -> Value {
        guard let field = RangeField(rawValue: key.lowercased()), let limits = field.parseLimits(limitsText) else { return .unknown }
        guard let v = field.value(of: ctx.metadata) else { return .missing(field.missingLabel) }
        return .text(field.rangeName(for: v, limits: limits))
    }

    /// A problem with the template's fields (unknown field, unreadable range limits), if any.
    public static func problem(in template: String) -> String? {
        var rest = Substring(template)
        while let open = rest.firstIndex(of: "{"), let close = rest[open...].firstIndex(of: "}") {
            let inner = String(rest[rest.index(after: open)..<close])
            if let bar = inner.firstIndex(of: "|") {
                let key = String(inner[..<bar])
                guard let field = RangeField(rawValue: key.lowercased()) else {
                    return "“{\(inner)}”: ranges work with size, duration, res or fps"
                }
                if field.parseLimits(String(inner[inner.index(after: bar)...])) == nil {
                    return "“{\(inner)}”: couldn’t read the limits (e.g. \(field.placeholder.replacingOccurrences(of: "e.g. ", with: "")))"
                }
            } else if case .unknown = value(split(inner).0, split(inner).1, Context(metadata: FileMetadata(), name: "x", ext: "x")) {
                return "“{\(inner)}” isn’t a known field"
            }
            rest = rest[rest.index(after: close)...]
        }
        return nil
    }

    static func label(for key: String) -> String? {
        switch key {
        case "taken": "Date taken"
        case "created": "Date created"
        case "modified": "Date modified"
        case "date": "Date"
        case "camera", "make", "model": "Camera"
        case "lens": "Lens"
        case "iso": "ISO"
        case "aperture": "Aperture"
        case "focal": "Focal length"
        case "resolution", "width", "height": "Resolution"
        case "duration": "Duration"
        case "fps": "Frame rate"
        case "codec": "Video codec"
        case "title": "Title"
        case "quality", "res": "Resolution"
        case "size": "Size"
        default: nil
        }
    }

    static func value(_ key: String, _ arg: String?, _ ctx: Context) -> Value {
        let m = ctx.metadata
        func date(_ d: Date?, _ label: String) -> Value {
            guard let d else { return .missing(label) }
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = arg ?? "yyyy-MM-dd"
            return .text(f.string(from: d))
        }
        func text(_ s: String?, _ label: String) -> Value {
            guard let s, !s.trimmingCharacters(in: .whitespaces).isEmpty else { return .missing(label) }
            return .text(s.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        func number(_ x: Double?, _ label: String, _ format: (Double) -> String) -> Value {
            guard let x, x > 0 else { return .missing(label) }
            return .text(format(x))
        }
        switch key {
        case "taken": return date(m?.taken, "Date taken")
        case "created": return date(m?.created, "Date created")
        case "modified": return date(m?.modified, "Date modified")
        case "date": return date(m?.taken ?? m?.created, "Date")
        case "camera": return text(m?.camera, "Camera")
        case "make": return text(m?.make, "Camera make")
        case "model": return text(m?.model, "Camera model")
        case "lens": return text(m?.lens, "Lens")
        case "iso": return number(m?.iso.map(Double.init), "ISO") { "ISO\(Int($0))" }
        case "aperture": return number(m?.fNumber, "Aperture") { "f" + trim($0, 1) }
        case "focal": return number(m?.focalLength, "Focal length") { trim($0, 0) + "mm" }
        case "width": return number(m?.width.map(Double.init), "Resolution") { String(Int($0)) }
        case "height": return number(m?.height.map(Double.init), "Resolution") { String(Int($0)) }
        case "resolution":
            guard let w = m?.width, let h = m?.height, w > 0, h > 0 else { return .missing("Resolution") }
            return .text("\(w)x\(h)")
        case "duration":
            guard let d = m?.duration, d > 0 else { return .missing("Duration") }
            if arg == "s" { return .text(String(Int(d.rounded()))) }
            return .text(formatDuration(d))
        case "fps": return number(m?.fps, "Frame rate") { trim($0, 2) }
        case "codec": return text(m?.codec, "Video codec")
        case "quality":
            guard let p = RangeField.pEquivalent(width: m?.width, height: m?.height) else { return .missing("Resolution") }
            return .text(RangeField.quality(p))
        case "title":
            guard let t = m?.title?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return .missing("Title") }
            if arg == "clean" {
                guard let clean = ReleaseTitle.cleanOrNil(t) else { return .missing("Title") }
                return .text(clean)
            }
            return .text(t)
        case "type", "kind": return .text((m?.kind ?? .other).folderName)
        case "ext": return ctx.ext.isEmpty ? .missing("Extension") : .text(ctx.ext.lowercased())
        case "name": return .text(ctx.name)
        case "prefix":
            let n = Int(arg ?? "1") ?? 1
            return .text(String(ctx.name.prefix(max(1, n))))
        case "n":
            let digits = Int(arg ?? "1") ?? 1
            let s = String(ctx.number)
            return .text(String(repeating: "0", count: max(0, digits - s.count)) + s)
        default:
            if let g = Int(key), (1...9).contains(g) {
                return g <= ctx.groups.count && !ctx.groups[g - 1].isEmpty ? .text(ctx.groups[g - 1]) : .missing("Name part \(g)")
            }
            return .unknown
        }
    }

    static func trim(_ x: Double, _ decimals: Int) -> String {
        var s = String(format: "%.\(decimals)f", x)
        if s.contains(".") {
            while s.hasSuffix("0") { s.removeLast() }
            if s.hasSuffix(".") { s.removeLast() }
        }
        return s
    }

    static func formatDuration(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        if h > 0 { return String(format: "%dh%02dm%02ds", h, m, s) }
        if m > 0 { return String(format: "%dm%02ds", m, s) }
        return "\(s)s"
    }

    /// Names can't contain "/" or ":" on macOS.
    static func sanitize(_ s: String) -> String {
        s.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
    }
}

// MARK: - Suggestions

public enum MetadataSuggestions {
    /// How many of the files have a field, e.g. "Date taken: 97%".
    public struct Coverage: Identifiable, Sendable, Hashable {
        public let label: String
        public let token: String
        public let count: Int
        public let total: Int
        /// The most common value, e.g. "Canon EOS 100D".
        public let example: String?
        public var id: String { label }
        public var fraction: Double { total == 0 ? 0 : Double(count) / Double(total) }
    }

    public struct Suggestion: Identifiable, Sendable, Hashable {
        public let title: String
        public let template: String
        /// Share of files that have every field the template needs.
        public let fraction: Double
        public var id: String { template }
    }

    /// Fields found in at least one file, most common first.
    public static func coverage(_ metas: [FileMetadata]) -> [Coverage] {
        let total = metas.count
        func field(_ label: String, _ token: String, _ value: (FileMetadata) -> String?) -> Coverage? {
            let values = metas.compactMap(value).filter { !$0.isEmpty }
            guard !values.isEmpty else { return nil }
            let common = Dictionary(grouping: values, by: { $0 }).max { $0.value.count < $1.value.count }?.key
            return Coverage(label: label, token: token, count: values.count, total: total, example: common)
        }
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        let fields: [Coverage?] = [
            field("Date taken", "{taken:yyyy-MM-dd HH.mm.ss}") { $0.taken.map(df.string) },
            field("Camera", "{camera}") { $0.camera },
            field("Lens", "{lens}") { $0.lens },
            field("Resolution", "{resolution}") { m in m.width.flatMap { w in m.height.map { "\(w)x\($0)" } } },
            field("Duration", "{duration}") { $0.duration.map(NameTemplate.formatDuration) },
            field("Frame rate", "{fps}") { $0.fps.map { NameTemplate.trim($0, 2) + " fps" } },
            field("Video codec", "{codec}") { $0.codec },
            field("Title", "{title:clean}") { $0.title.flatMap(ReleaseTitle.cleanOrNil) },
            field("ISO", "{iso}") { $0.iso.map { "ISO\($0)" } },
            field("Aperture", "{aperture}") { $0.fNumber.map { "f" + NameTemplate.trim($0, 1) } },
            field("Focal length", "{focal}") { $0.focalLength.map { NameTemplate.trim($0, 0) + "mm" } },
        ]
        return fields.compactMap { $0 }.sorted { $0.count > $1.count }
    }

    /// Share of files a template fully works for.
    public static func fraction(_ template: String, _ metas: [FileMetadata]) -> Double {
        guard !metas.isEmpty else { return 0 }
        let ok = metas.filter { NameTemplate.render(template, .init(metadata: $0, name: "x", ext: "jpg")).missing.isEmpty }
        return Double(ok.count) / Double(metas.count)
    }

    /// Name ideas that fit most of these files (at least half of them).
    public static func renameSuggestions(_ metas: [FileMetadata]) -> [Suggestion] {
        let kinds = Dictionary(grouping: metas, by: \.kind).mapValues(\.count)
        let mostlyVideo = (kinds[.video] ?? 0) * 2 >= max(1, metas.count)
        var candidates: [(String, String)] = [
            ("Date and time taken", "{taken:yyyy-MM-dd HH.mm.ss}"),
            ("Date taken + camera", "{taken:yyyy-MM-dd HH.mm.ss} {camera}"),
            ("Date taken + counter", "{taken:yyyy-MM-dd} {n:3}"),
        ]
        if mostlyVideo {
            candidates.insert(("Date taken + resolution + frame rate", "{taken:yyyy-MM-dd HH.mm.ss} {resolution} {fps}fps"), at: 1)
            candidates.append(("Date taken + duration", "{taken:yyyy-MM-dd HH.mm.ss} {duration}"))
        }
        candidates += [
            ("Camera + counter", "{camera} {n:4}"),
            ("Date created + time", "{created:yyyy-MM-dd HH.mm.ss}"),
        ]
        // Titles stored inside videos (often the only clue for recovered files): offered whenever any file
        // has one — files without a title simply keep their names.
        let titles = rank([("Title inside the file (cleaned)", "{title:clean}"), ("Title inside the file, as is", "{title}")],
                          metas, minimum: 0.000_001)
        return titles + rank(candidates, metas)
    }

    /// Folder layouts that fit most of these files. "/" makes subfolders.
    public static func organizeSuggestions(_ metas: [FileMetadata]) -> [Suggestion] {
        let candidates: [(String, String)] = [
            ("By year and month taken", "{taken:yyyy}/{taken:MM}"),
            ("By day taken", "{taken:yyyy}/{taken:yyyy-MM-dd}"),
            ("By camera", "{camera}"),
            ("By year, then camera", "{taken:yyyy}/{camera}"),
            ("Photos / Videos / Other", "{type}"),
            ("By video quality (SD, 720p, 1080p, 4K)", "{quality}"),
            ("By length (under / over 30 min)", "{duration|30m}"),
            ("By size (under 100 MB / 100 MB – 1 GB / 1 GB+)", "{size|100MB,1GB}"),
            ("By file extension", "{ext}"),
            ("By year and month created", "{created:yyyy}/{created:MM}"),
        ]
        return rank(candidates, metas, minimum: 0.3)
    }

    static func rank(_ candidates: [(String, String)], _ metas: [FileMetadata], minimum: Double = 0.5) -> [Suggestion] {
        guard !metas.isEmpty else { return [] }
        var seen = Set<String>()
        return candidates
            .map { Suggestion(title: $0.0, template: $0.1, fraction: fraction($0.1, metas)) }
            .filter { $0.fraction >= minimum && seen.insert($0.template).inserted }
    }
}

// MARK: - Release-style titles

/// Turns titles like "RARBG.COM - Edge.of.Tomorrow.2014.1080p.WEBRip.HC.XviD.MP3-RARBG"
/// into readable names like "Edge of Tomorrow (2014)". Plain titles are left as they are.
public enum ReleaseTitle {
    static let siteTag = try! NSRegularExpression(
        pattern: #"^\s*(\[[^\]]*\]|\([^)]*\)|www\.\S+|[A-Za-z0-9-]+\.(com|org|net|to|ws|io|me|cc|tv|in|info|co|ag|lt|mx|se|nu|eu|xyz|club|site|top|am|is|li|pw|ch|ru|lol|vip|st|pro|biz))(?=[\s._\-–:|]|$)[\s._\-–:|]*"#,
        options: [.caseInsensitive])
    static let techToken = try! NSRegularExpression(
        pattern: #"^(\d{3,4}p|4k|8k|uhd|hdr\d*|sdr|dv|web[-]?rip|web[-]?dl|web|hd[-]?rip|hc|bluray|blu[-]?ray|brrip|bdrip|bd|dvd[-]?rip|dvdscr|dvd|hdtv|pdtv|camrip|cam|hdcam|telesync|ts|tc|xvid|divx|x26[45]|h\.?26[45]|hevc|avc|aac\d?(\.\d)?|ac3|eac3|dd\d?(\.\d)?|dts(-hd)?|truehd|atmos|mp3|flac|10bit|8bit|remux|proper|repack|extended|unrated|uncut|internal|limited|multi|dual|dubbed|subbed|hardsub|nf|amzn|dsnp|hmax|hulu|imax|yify|yts|rarbg)$"#,
        options: [.caseInsensitive])
    static let episode = try! NSRegularExpression(pattern: #"^S\d{1,2}E\d{1,3}(E\d{1,3})?$"#, options: [.caseInsensitive])

    public static func clean(_ raw: String) -> String {
        cleanOrNil(raw) ?? raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The readable title, or nil when nothing useful is left (blank, or only a site name like "EXAMPLE.COM").
    public static func cleanOrNil(_ raw: String) -> String? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty, !isAdvert(s) else { return nil }
        // Site and group tags at the start (may be stacked).
        for _ in 0..<3 {
            let range = NSRange(s.startIndex..., in: s)
            guard let m = siteTag.firstMatch(in: s, range: range), m.range.length > 0, let r = Range(m.range, in: s) else { break }
            s.removeSubrange(r)
        }
        // "Edge.of.Tomorrow" → "Edge of Tomorrow" (only for dotted/underscored release names).
        let dots = s.filter { $0 == "." || $0 == "_" }.count
        if dots >= 2 && dots >= s.filter({ $0 == " " }).count {
            s = s.replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: ".", with: " ")
        }
        var tokens = s.split(separator: " ").map(String.init)
        guard !tokens.isEmpty else { return nil } // only site tags
        // A trailing release group: "MP3-RARBG" → "MP3".
        if let last = tokens.last, let dash = last.lastIndex(of: "-"), dash != last.startIndex {
            let before = String(last[..<dash])
            if matches(techToken, before) { tokens[tokens.count - 1] = before }
        }
        func isYear(_ t: String) -> Bool {
            let digits = t.trimmingCharacters(in: CharacterSet(charactersIn: "()[]"))
            guard digits.count == 4, let y = Int(digits) else { return false }
            return (1900...2099).contains(y)
        }
        var result: String?
        for (i, t) in tokens.enumerated() where i > 0 {
            if matches(episode, t) {
                result = tokens[0...i].joined(separator: " ").uppercasedEpisode()
                break
            }
            if isYear(t) {
                let name = tokens[0..<i].joined(separator: " ")
                result = "\(name) (\(t.trimmingCharacters(in: CharacterSet(charactersIn: "()[]"))))"
                break
            }
            if matches(techToken, t) {
                result = tokens[0..<i].joined(separator: " ")
                break
            }
        }
        let cleaned = (result ?? tokens.joined(separator: " "))
            .trimmingCharacters(in: CharacterSet(charactersIn: " -–_.:|<>"))
        if cleaned.isEmpty || isAdvert(cleaned) { return nil }
        return cleaned
    }

    static let domain = try! NSRegularExpression(pattern: #"\b[\w-]+\.(com|org|net|to|ws|io|me|cc|tv|in|info|co|ag|lt|mx|se|nu|eu|xyz|club|site|top|am|is|li|pw|ch|ru|lol|vip|st|pro|biz)\b"#,
                                                 options: [.caseInsensitive])
    static let advertWords: Set<String> = ["visit", "download", "downloaded", "from", "at", "www", "by", "for", "more", "free", "movies", "movie", "only", "on"]

    /// "> VISIT - MICROMKV.COM <": a site name plus filler words, not a title.
    static func isAdvert(_ text: String) -> Bool {
        let range = NSRange(text.startIndex..., in: text)
        guard domain.firstMatch(in: text, range: range) != nil else { return false }
        let withoutDomains = domain.stringByReplacingMatches(in: text, range: range, withTemplate: " ")
        let words = withoutDomains.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
        return words.allSatisfy { advertWords.contains($0) }
    }

    /// A "title" that's really a timestamp (phones often write the recording time as the title).
    public static func dateIfTimestamp(_ text: String) -> Date? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.count >= 10, t.first?.isNumber == true else { return nil }
        let iso = ISO8601DateFormatter()
        for options: ISO8601DateFormatter.Options in [[.withInternetDateTime], [.withFullDate, .withTime, .withColonSeparatorInTime, .withDashSeparatorInDate]] {
            iso.formatOptions = options
            if let d = iso.date(from: t) { return d }
        }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        for format in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd HH:mm:ss", "yyyy:MM:dd HH:mm:ss", "yyyy-MM-dd"] {
            f.dateFormat = format
            if let d = f.date(from: t) { return d }
        }
        return nil
    }

    static func matches(_ regex: NSRegularExpression, _ text: String) -> Bool {
        regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }
}

private extension String {
    /// "Show Name s01e02" → "Show Name S01E02".
    func uppercasedEpisode() -> String {
        guard let last = split(separator: " ").last else { return self }
        return dropLast(last.count) + last.uppercased()
    }
}
