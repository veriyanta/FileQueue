import CryptoKit
import Foundation

/// One copy of a duplicated file.
public struct DuplicateFile: Sendable, Hashable, Identifiable {
    public let url: URL
    public let size: Int64
    public let modified: Date?
    public let created: Date?
    public var id: URL { url }
    public var name: String { url.lastPathComponent }

    public init(url: URL, size: Int64, modified: Date?, created: Date?) {
        self.url = url
        self.size = size
        self.modified = modified
        self.created = created
    }

    init(url: URL) {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .creationDateKey])
        self.init(url: url, size: Int64(values?.fileSize ?? 0), modified: values?.contentModificationDate, created: values?.creationDate)
    }
}

/// Files that look like copies of each other.
public struct DuplicateGroup: Sendable, Identifiable, Hashable {
    public let id: UUID
    public var files: [DuplicateFile]
    /// Every byte was compared (or the files are small enough that the quick check read all of them).
    /// Otherwise they matched on size plus samples of their contents: very likely, not certain.
    public var verified: Bool

    public init(id: UUID = UUID(), files: [DuplicateFile], verified: Bool) {
        self.id = id
        self.files = files
        self.verified = verified
    }

    public var size: Int64 { files.first?.size ?? 0 }
    /// Space freed by keeping just one.
    public var extraBytes: Int64 { size * Int64(max(0, files.count - 1)) }
}

/// Which copy to keep, by default.
public enum KeepRule: String, CaseIterable, Identifiable, Sendable, Codable {
    /// The one whose name doesn't look like a copy ("name 2", "name (1)", "name copy"), then the oldest.
    case bestName
    case oldest, newest
    /// The one nearest the top of the folder.
    case shallowest
    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .bestName: "Original-looking name"
        case .oldest: "Oldest"
        case .newest: "Newest"
        case .shallowest: "Nearest the top folder"
        }
    }
}

public enum DuplicateFinder {
    public struct Options: Sendable, Hashable {
        public var includeSubfolders: Bool
        public var includeHidden: Bool
        /// Smaller files are ignored (tiny files are often legitimately identical, e.g. empty placeholders).
        public var minimumSize: Int64
        /// Compare every byte instead of samples (slow on big files, but certain).
        public var everyByte: Bool
        public init(includeSubfolders: Bool = true, includeHidden: Bool = false, minimumSize: Int64 = 1, everyByte: Bool = false) {
            self.includeSubfolders = includeSubfolders
            self.includeHidden = includeHidden
            self.minimumSize = minimumSize
            self.everyByte = everyByte
        }
    }

    public struct Progress: Sendable {
        public enum Phase: Sendable { case listing, comparing }
        public var phase: Phase
        public var done: Int
        public var total: Int
        public var current: String
    }

    /// Finds groups of files with the same contents in `folder`, biggest waste first.
    /// Files are grouped by size first, so only same-sized files are ever read.
    public static func find(in folder: URL, options: Options = Options(),
                            progress: (@Sendable (Progress) -> Void)? = nil,
                            isCancelled: @Sendable () -> Bool = { false }) -> [DuplicateGroup] {
        // 1. List files and group them by size.
        var bySize: [Int64: [DuplicateFile]] = [:]
        var listed = 0
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey, .creationDateKey]
        var mask: FileManager.DirectoryEnumerationOptions = [.skipsPackageDescendants]
        if !options.includeSubfolders { mask.insert(.skipsSubdirectoryDescendants) }
        if !options.includeHidden { mask.insert(.skipsHiddenFiles) }
        guard let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: keys, options: mask,
                                                          errorHandler: { _, _ in true }) else { return [] }
        for case let url as URL in walker {
            if isCancelled() { return [] }
            let name = url.lastPathComponent
            if name.hasPrefix("._") || name == ".DS_Store" || name.hasSuffix(".fqpart") { continue }
            guard let v = try? url.resourceValues(forKeys: Set(keys)), v.isRegularFile == true, v.isSymbolicLink != true else { continue }
            let size = Int64(v.fileSize ?? 0)
            guard size >= max(1, options.minimumSize) else { continue }
            bySize[size, default: []].append(DuplicateFile(url: url, size: size, modified: v.contentModificationDate, created: v.creationDate))
            listed += 1
            if listed % 500 == 0 { progress?(Progress(phase: .listing, done: listed, total: 0, current: name)) }
        }

        // 2. Within each size, group by a fingerprint of the contents.
        let candidates = bySize.values.filter { $0.count > 1 }
        let total = candidates.reduce(0) { $0 + $1.count }
        var done = 0
        var groups: [DuplicateGroup] = []
        for sameSize in candidates.sorted(by: { $0[0].size > $1[0].size }) {
            var byPrint: [Data: [DuplicateFile]] = [:]
            for file in sameSize {
                if isCancelled() { return [] }
                progress?(Progress(phase: .comparing, done: done, total: total, current: file.name))
                done += 1
                let print = options.everyByte ? try? FS.sha256(file.url) : try? fingerprint(file.url, size: UInt64(file.size))
                guard let print else { continue } // unreadable: leave it out
                byPrint[print, default: []].append(file)
            }
            let complete = options.everyByte || FS.quickCheckIsComplete(size: UInt64(sameSize[0].size))
            for files in byPrint.values where files.count > 1 {
                groups.append(DuplicateGroup(files: files.sorted(by: pathOrder), verified: complete))
            }
        }
        progress?(Progress(phase: .comparing, done: total, total: total, current: ""))
        return groups.sorted { ($0.extraBytes, $0.files[0].url.path) > ($1.extraBytes, $1.files[0].url.path) }
    }

    /// SHA-256 of the sampled parts of a file (see `FS.sampleRanges`).
    static func fingerprint(_ url: URL, size: UInt64) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        for range in FS.sampleRanges(size: size) {
            try handle.seek(toOffset: range.lowerBound)
            guard let data = try handle.read(upToCount: Int(range.upperBound - range.lowerBound)),
                  data.count == Int(range.upperBound - range.lowerBound) else { throw CocoaError(.fileReadCorruptFile) }
            hasher.update(data: data)
        }
        return Data(hasher.finalize())
    }

    /// Compares every byte of a group's files. Returns the groups that really match
    /// (one group can split into several, or vanish if nothing matches).
    public static func verify(_ group: DuplicateGroup, isCancelled: @Sendable () -> Bool = { false }) -> [DuplicateGroup] {
        if group.verified { return [group] }
        var byHash: [Data: [DuplicateFile]] = [:]
        for file in group.files {
            if isCancelled() { return [] }
            guard let hash = try? FS.sha256(file.url) else { continue }
            byHash[hash, default: []].append(file)
        }
        return byHash.values.filter { $0.count > 1 }.map { DuplicateGroup(files: $0.sorted(by: pathOrder), verified: true) }
    }

    static func pathOrder(_ a: DuplicateFile, _ b: DuplicateFile) -> Bool {
        a.url.path.localizedStandardCompare(b.url.path) == .orderedAscending
    }

    /// The copy to keep by default.
    public static func keeper(of group: DuplicateGroup, rule: KeepRule) -> DuplicateFile? {
        func date(_ f: DuplicateFile) -> Date { [f.created, f.modified].compactMap { $0 }.min() ?? .distantFuture }
        func depth(_ f: DuplicateFile) -> Int { f.url.pathComponents.count }
        let files = group.files
        switch rule {
        case .oldest: return files.min { (date($0), depth($0)) < (date($1), depth($1)) }
        case .newest: return files.max { date($0) < date($1) }
        case .shallowest: return files.min { (depth($0), date($0)) < (depth($1), date($1)) }
        case .bestName:
            return files.min { a, b in
                let ca = looksLikeCopy(a.name), cb = looksLikeCopy(b.name)
                if ca != cb { return !ca }
                if a.name.count != b.name.count { return a.name.count < b.name.count }
                return date(a) < date(b)
            }
        }
    }

    /// "photo 2.jpg", "photo (1).jpg", "photo copy.jpg", "photo - Copy.jpg", "photo-1.jpg".
    public static func looksLikeCopy(_ name: String) -> Bool {
        let base = (name as NSString).deletingPathExtension.lowercased()
        let patterns = [#"\s\d+$"#, #"\s?\(\d+\)$"#, #"\scopy(\s\d+)?$"#, #"\s-\scopy(\s\(\d+\))?$"#, #"-\d$"#]
        return patterns.contains { base.range(of: $0, options: .regularExpression) != nil }
    }
}
