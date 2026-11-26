import Foundation
import ImageIO

// MARK: - Rules

/// One step of a batch-rename pipeline. A flat struct (rather than an enum) so the UI can
/// bind each field directly; only the fields relevant to `kind` are used.
public struct RenameRule: Codable, Sendable, Hashable, Identifiable {
    public enum Kind: String, Codable, Sendable, CaseIterable, Identifiable {
        case metadata, replace, addPrefix, addSuffix, insert, remove, changeCase, sequence, date, setExtension, trimWhitespace
        public var id: String { rawValue }
        public var label: String {
            switch self {
            case .metadata: "Metadata (photo/video details)"
            case .replace: "Replace Text"
            case .addPrefix: "Add Prefix"
            case .addSuffix: "Add Suffix"
            case .insert: "Insert Text"
            case .remove: "Remove Characters"
            case .changeCase: "Change Case"
            case .sequence: "Add Number"
            case .date: "Add Date"
            case .setExtension: "Change Extension"
            case .trimWhitespace: "Trim Spaces"
            }
        }
    }

    public enum CaseStyle: String, Codable, Sendable, CaseIterable, Identifiable {
        case lower, upper, title, sentence
        public var id: String { rawValue }
        public var label: String {
            switch self {
            case .lower: "lowercase"
            case .upper: "UPPERCASE"
            case .title: "Title Case"
            case .sentence: "Sentence case"
            }
        }
    }

    public enum Placement: String, Codable, Sendable, CaseIterable, Identifiable {
        case prefix, suffix, replace
        public var id: String { rawValue }
        public var label: String {
            switch self {
            case .prefix: "Before name"
            case .suffix: "After name"
            case .replace: "Replace name"
            }
        }
    }

    public enum DateSource: String, Codable, Sendable, CaseIterable, Identifiable {
        case created, modified, exif
        public var id: String { rawValue }
        public var label: String {
            switch self {
            case .created: "Date created"
            case .modified: "Date modified"
            case .exif: "Photo taken (EXIF)"
            }
        }
    }

    public var id = UUID()
    public var kind: Kind
    public var isEnabled = true
    /// Find text, prefix, suffix, inserted text or new extension.
    public var text = ""
    public var replacement = ""
    public var useRegex = false
    public var caseSensitive = false
    /// Insert position / first character to remove (0-based).
    public var position = 0
    public var count = 1
    public var caseStyle: CaseStyle = .lower
    public var start = 1
    public var step = 1
    public var padding = 3
    public var placement: Placement = .suffix
    public var separator = " "
    public var dateSource: DateSource = .modified
    public var dateFormat = "yyyy-MM-dd"
    /// Sequence: start again at `start` in each folder.
    public var perFolder = false

    public init(kind: Kind) {
        self.kind = kind
        if kind == .sequence || kind == .date { separator = "_" }
        if kind == .metadata {
            placement = .replace
            separator = " "
            text = "{taken:yyyy-MM-dd HH.mm.ss}"
        }
    }

    enum CodingKeys: String, CodingKey {
        case id, kind, isEnabled, text, replacement, useRegex, caseSensitive, position, count, caseStyle
        case start, step, padding, placement, separator, dateSource, dateFormat, perFolder
    }

    /// Presets saved by earlier versions may lack newer fields.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decode(Kind.self, forKey: .kind)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        isEnabled = try c.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        replacement = try c.decodeIfPresent(String.self, forKey: .replacement) ?? ""
        useRegex = try c.decodeIfPresent(Bool.self, forKey: .useRegex) ?? false
        caseSensitive = try c.decodeIfPresent(Bool.self, forKey: .caseSensitive) ?? false
        position = try c.decodeIfPresent(Int.self, forKey: .position) ?? 0
        count = try c.decodeIfPresent(Int.self, forKey: .count) ?? 1
        caseStyle = try c.decodeIfPresent(CaseStyle.self, forKey: .caseStyle) ?? .lower
        start = try c.decodeIfPresent(Int.self, forKey: .start) ?? 1
        step = try c.decodeIfPresent(Int.self, forKey: .step) ?? 1
        padding = try c.decodeIfPresent(Int.self, forKey: .padding) ?? 3
        placement = try c.decodeIfPresent(Placement.self, forKey: .placement) ?? .suffix
        separator = try c.decodeIfPresent(String.self, forKey: .separator) ?? " "
        dateSource = try c.decodeIfPresent(DateSource.self, forKey: .dateSource) ?? .modified
        dateFormat = try c.decodeIfPresent(String.self, forKey: .dateFormat) ?? "yyyy-MM-dd"
        perFolder = try c.decodeIfPresent(Bool.self, forKey: .perFolder) ?? false
    }

    public static func metadata(_ template: String, placement: Placement = .replace, separator: String = " ") -> RenameRule {
        var r = RenameRule(kind: .metadata)
        r.text = template; r.placement = placement; r.separator = separator
        return r
    }

    public static func replace(_ find: String, with replacement: String, regex: Bool = false, caseSensitive: Bool = false) -> RenameRule {
        var r = RenameRule(kind: .replace)
        r.text = find; r.replacement = replacement; r.useRegex = regex; r.caseSensitive = caseSensitive
        return r
    }

    public static func prefix(_ text: String) -> RenameRule { var r = RenameRule(kind: .addPrefix); r.text = text; return r }
    public static func suffix(_ text: String) -> RenameRule { var r = RenameRule(kind: .addSuffix); r.text = text; return r }
    public static func insert(_ text: String, at position: Int) -> RenameRule {
        var r = RenameRule(kind: .insert); r.text = text; r.position = position; return r
    }
    public static func remove(from position: Int, count: Int) -> RenameRule {
        var r = RenameRule(kind: .remove); r.position = position; r.count = count; return r
    }
    public static func changeCase(_ style: CaseStyle) -> RenameRule { var r = RenameRule(kind: .changeCase); r.caseStyle = style; return r }
    public static func sequence(start: Int = 1, step: Int = 1, padding: Int = 3, placement: Placement = .suffix, separator: String = "_") -> RenameRule {
        var r = RenameRule(kind: .sequence)
        r.start = start; r.step = step; r.padding = padding; r.placement = placement; r.separator = separator
        return r
    }
    public static func date(_ source: DateSource, format: String = "yyyy-MM-dd", placement: Placement = .prefix, separator: String = "_") -> RenameRule {
        var r = RenameRule(kind: .date)
        r.dateSource = source; r.dateFormat = format; r.placement = placement; r.separator = separator
        return r
    }
    public static func setExtension(_ ext: String) -> RenameRule { var r = RenameRule(kind: .setExtension); r.text = ext; return r }
    public static var trimWhitespace: RenameRule { RenameRule(kind: .trimWhitespace) }
}

// MARK: - Metadata

public protocol FileMetadataProviding: Sendable {
    /// A folder that is not a package (its whole name is the "base", it has no extension).
    func isPlainFolder(_ url: URL) -> Bool
    func date(_ source: RenameRule.DateSource, of url: URL) -> Date?
    func existingNames(in directory: URL) -> [String]
    func isCaseSensitive(_ directory: URL) -> Bool
}

public struct SystemMetadataProvider: FileMetadataProviding {
    public init() {}

    public func isPlainFolder(_ url: URL) -> Bool {
        let v = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
        return v?.isDirectory == true && v?.isPackage != true
    }

    public func date(_ source: RenameRule.DateSource, of url: URL) -> Date? {
        let v = try? url.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
        switch source {
        case .created: return v?.creationDate
        case .modified: return v?.contentModificationDate
        case .exif: return exifDate(url) ?? v?.creationDate
        }
    }

    private func exifDate(_ url: URL) -> Date? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any],
              let raw = exif[kCGImagePropertyExifDateTimeOriginal] as? String
        else { return nil }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return f.date(from: raw)
    }

    public func existingNames(in directory: URL) -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
    }

    public func isCaseSensitive(_ directory: URL) -> Bool {
        (try? directory.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey]))?.volumeSupportsCaseSensitiveNames ?? false
    }
}

// MARK: - Engine

public enum RenameEngine {
    struct RuleError: Error { let message: String }

    /// Builds a full preview: every file's proposed name and whether it can be used.
    public struct Options: Sendable, Hashable {
        /// When several files would get the same name, add " 2", " 3"… instead of flagging a clash.
        public var numberDuplicates: Bool
        public init(numberDuplicates: Bool = false) { self.numberDuplicates = numberDuplicates }
    }

    struct MissingMetadata: Error { let labels: [String] }

    public static func makePlan(
        files: [URL], rules: [RenameRule], metadata: any FileMetadataProviding = SystemMetadataProvider(),
        fileMetadata: [URL: FileMetadata] = [:], options: Options = Options(), unread: Set<URL> = []
    ) -> [RenamePlanItem] {
        let active = rules.filter(\.isEnabled)
        let needsDetails = active.contains { $0.kind == .metadata && NameTemplate.needsDetails($0.text) }
        // Position of each file overall and within its own folder (for counters).
        var perFolderCount: [URL: Int] = [:]
        let positions: [(overall: Int, inFolder: Int)] = files.enumerated().map { index, url in
            let dir = url.deletingLastPathComponent()
            let inFolder = perFolderCount[dir, default: 0]
            perFolderCount[dir] = inFolder + 1
            return (index, inFolder)
        }
        var items: [RenamePlanItem] = files.enumerated().map { index, url in
            if needsDetails && unread.contains(url) {
                return RenamePlanItem(original: url, proposedName: url.lastPathComponent, status: .notRead)
            }
            do {
                let name = try newName(for: url, index: positions[index].overall, folderIndex: positions[index].inFolder,
                                       rules: active, metadata: metadata, fileMetadata: fileMetadata[url])
                if let reason = FS.validateName(name) {
                    return RenamePlanItem(original: url, proposedName: name, status: .invalid(reason))
                }
                let status: RenameStatus = name == url.lastPathComponent ? .unchanged : .ok
                return RenamePlanItem(original: url, proposedName: name, status: status)
            } catch let missing as MissingMetadata {
                return RenamePlanItem(original: url, proposedName: url.lastPathComponent,
                                      status: .missingMetadata(missing.labels.joined(separator: ", ")))
            } catch let error as RuleError {
                return RenamePlanItem(original: url, proposedName: url.lastPathComponent, status: .invalid(error.message))
            } catch {
                return RenamePlanItem(original: url, proposedName: url.lastPathComponent, status: .invalid("\(error)"))
            }
        }
        if options.numberDuplicates { numberDuplicates(&items, metadata: metadata) }
        markCollisions(&items, metadata: metadata)
        return items
    }

    /// "IMG.jpg", "IMG.jpg" → "IMG.jpg", "IMG 2.jpg" (per folder, avoiding names already taken).
    static func numberDuplicates(_ items: inout [RenamePlanItem], metadata: any FileMetadataProviding) {
        let byFolder = Dictionary(grouping: items.indices) { items[$0].original.deletingLastPathComponent().standardizedFileURL }
        for (dir, indices) in byFolder {
            let caseSensitive = metadata.isCaseSensitive(dir)
            func key(_ name: String) -> String {
                let nfc = name.precomposedStringWithCanonicalMapping
                return caseSensitive ? nfc : nfc.lowercased()
            }
            let batchOriginals = Set(indices.map { key(items[$0].original.lastPathComponent) })
            var taken = Set(metadata.existingNames(in: dir).map(key)).subtracting(batchOriginals)
            // Files that keep their name hold it first.
            for i in indices where !(items[i].status == .ok) { taken.insert(key(items[i].proposedName)) }
            for i in indices where items[i].status == .ok {
                var name = items[i].proposedName
                if taken.contains(key(name)) {
                    let ext = (name as NSString).pathExtension
                    let base = ext.isEmpty ? name : String(name.dropLast(ext.count + 1))
                    var n = 2
                    repeat {
                        name = ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)"
                        n += 1
                    } while taken.contains(key(name))
                    items[i].proposedName = name
                    items[i].status = name == items[i].original.lastPathComponent ? .unchanged : .ok
                }
                taken.insert(key(name))
            }
        }
    }

    /// Applies the rules to one file's name.
    public static func newName(
        for url: URL, index: Int, folderIndex: Int? = nil, rules: [RenameRule], metadata: any FileMetadataProviding,
        fileMetadata: FileMetadata? = nil
    ) throws -> String {
        let fullName = url.lastPathComponent
        var base: String
        var ext: String
        if metadata.isPlainFolder(url) || url.pathExtension.isEmpty {
            base = fullName
            ext = ""
        } else {
            ext = url.pathExtension
            base = String(fullName.dropLast(ext.count + 1))
        }

        for rule in rules {
            switch rule.kind {
            case .replace:
                guard !rule.text.isEmpty else { break }
                if rule.useRegex {
                    let regex: NSRegularExpression
                    do {
                        regex = try NSRegularExpression(pattern: rule.text, options: rule.caseSensitive ? [] : [.caseInsensitive])
                    } catch {
                        throw RuleError(message: "Invalid pattern")
                    }
                    base = regex.stringByReplacingMatches(
                        in: base, range: NSRange(base.startIndex..., in: base), withTemplate: rule.replacement)
                } else {
                    base = base.replacingOccurrences(
                        of: rule.text, with: rule.replacement, options: rule.caseSensitive ? [] : [.caseInsensitive])
                }
            case .addPrefix:
                base = rule.text + base
            case .addSuffix:
                base += rule.text
            case .insert:
                let at = min(max(0, rule.position), base.count)
                let i = base.index(base.startIndex, offsetBy: at)
                base.insert(contentsOf: rule.text, at: i)
            case .remove:
                let from = min(max(0, rule.position), base.count)
                let to = min(base.count, from + max(0, rule.count))
                let a = base.index(base.startIndex, offsetBy: from)
                let b = base.index(base.startIndex, offsetBy: to)
                base.removeSubrange(a..<b)
            case .changeCase:
                switch rule.caseStyle {
                case .lower: base = base.lowercased()
                case .upper: base = base.uppercased()
                case .title: base = base.capitalized
                case .sentence:
                    let lower = base.lowercased()
                    base = lower.prefix(1).uppercased() + lower.dropFirst()
                }
            case .metadata:
                let rendered = NameTemplate.render(rule.text, .init(
                    metadata: fileMetadata, name: base, ext: ext,
                    number: rule.start + (rule.perFolder ? (folderIndex ?? index) : index) * rule.step))
                if !rendered.missing.isEmpty { throw MissingMetadata(labels: rendered.missing) }
                switch rule.placement {
                case .replace: base = rendered.text
                case .prefix: base = rendered.text + rule.separator + base
                case .suffix: base = base + rule.separator + rendered.text
                }
            case .sequence:
                let n = rule.start + (rule.perFolder ? (folderIndex ?? index) : index) * rule.step
                let digits = String(abs(n))
                let padded = String(repeating: "0", count: max(0, rule.padding - digits.count)) + digits
                let number = n < 0 ? "-" + padded : padded
                switch rule.placement {
                case .prefix: base = number + rule.separator + base
                case .suffix: base = base + rule.separator + number
                case .replace: base = number
                }
            case .date:
                guard let date = metadata.date(rule.dateSource, of: url) else { break }
                let f = DateFormatter()
                f.locale = Locale(identifier: "en_US_POSIX")
                f.dateFormat = rule.dateFormat
                let text = f.string(from: date)
                switch rule.placement {
                case .prefix: base = text + rule.separator + base
                case .suffix: base = base + rule.separator + text
                case .replace: base = text
                }
            case .setExtension:
                ext = rule.text.hasPrefix(".") ? String(rule.text.dropFirst()) : rule.text
            case .trimWhitespace:
                base = base.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return ext.isEmpty ? base : base + "." + ext
    }

    /// Flags names that clash with each other or with files already in the folder.
    static func markCollisions(_ items: inout [RenamePlanItem], metadata: any FileMetadataProviding) {
        let directories = Set(items.map { $0.original.deletingLastPathComponent().standardizedFileURL })
        for dir in directories {
            let caseSensitive = metadata.isCaseSensitive(dir)
            func key(_ name: String) -> String {
                let nfc = name.precomposedStringWithCanonicalMapping
                return caseSensitive ? nfc : nfc.lowercased()
            }
            let indices = items.indices.filter { items[$0].original.deletingLastPathComponent().standardizedFileURL == dir }

            // Final names within the batch (unchanged items keep their name).
            var finalKeys: [String: [Int]] = [:]
            for i in indices where !items[i].status.isError {
                finalKeys[key(items[i].proposedName), default: []].append(i)
            }
            for (_, owners) in finalKeys where owners.count > 1 {
                for i in owners where items[i].status == .ok || items[i].status == .unchanged {
                    items[i].status = .collidesWithinBatch
                }
            }

            // Names already on disk that aren't being renamed away by this batch.
            let batchOriginals = Set(indices.map { key(items[$0].original.lastPathComponent) })
            let existing = Set(metadata.existingNames(in: dir).map(key))
            let staying = existing.subtracting(batchOriginals)
            for i in indices where items[i].status == .ok {
                if staying.contains(key(items[i].proposedName)) {
                    items[i].status = .collidesWithExisting
                }
            }
        }
    }
}
