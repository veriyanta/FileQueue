import Foundation

/// Lists the files to work on, optionally looking inside folders (and their subfolders).
public enum FileExpander {
    /// - Files are kept as they are. Folders are replaced by every file inside them when `recursive`,
    ///   otherwise kept as single items. Hidden files and the insides of packages (e.g. .app) are skipped.
    public static func expand(_ urls: [URL], recursive: Bool) -> [URL] {
        var result: [URL] = []
        var seen = Set<URL>()
        func add(_ url: URL) { if seen.insert(url.standardizedFileURL).inserted { result.append(url.standardizedFileURL) } }
        for url in urls {
            guard recursive, FS.isMergeableFolder(url) else { add(url); continue }
            let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey]
            let enumerator = FileManager.default.enumerator(
                at: url, includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles, .skipsPackageDescendants], errorHandler: { _, _ in true })
            var files: [URL] = []
            while let item = enumerator?.nextObject() as? URL {
                let v = try? item.resourceValues(forKeys: Set(keys))
                if v?.isDirectory == true && v?.isPackage != true { continue }
                files.append(item)
            }
            files.sort { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
            files.forEach(add)
        }
        return result
    }
}

// MARK: - Organize

public enum OrganizeStatus: Codable, Sendable, Hashable {
    case ok
    /// The file lacked a detail the layout needs, so it goes to the fallback folder.
    case fallback(String)
    /// Already where it would go.
    case unchanged
    /// The layout needs this file's details, which haven't been read yet.
    case notRead
    case invalid(String)

    public var willMove: Bool {
        switch self {
        case .ok, .fallback: true
        default: false
        }
    }
}

public struct OrganizeItem: Codable, Sendable, Hashable, Identifiable {
    public var source: URL
    public var destination: URL
    public var status: OrganizeStatus
    public var id: URL { source }

    public init(source: URL, destination: URL, status: OrganizeStatus) {
        self.source = source
        self.destination = destination
        self.status = status
    }
}

public struct OrganizeOptions: Sendable, Hashable {
    /// Folder layout; "/" makes subfolders, e.g. "{taken:yyyy}/{taken:MM}".
    public var template: String
    /// Optional regular expression matched against the file name; its groups are {1}…{9}.
    public var namePattern: String
    /// Where files go when they lack a detail the layout needs.
    public var fallbackFolder: String
    /// When two files would land on the same name, add " 2", " 3"…
    public var numberDuplicates: Bool
    /// A folder never gets more than this many items: beyond it, files go into numbered subfolders
    /// 001, 002… (folders with huge numbers of files are slow to open). 0 = no limit.
    public var maxPerFolder: Int
    /// Optional new file name (without extension), e.g. "{title:clean}". Empty keeps names as they are;
    /// a file missing a detail the name needs keeps its name too. The extension is always kept.
    public var nameTemplate: String

    public init(template: String, namePattern: String = "", fallbackFolder: String = "Unsorted",
                numberDuplicates: Bool = true, maxPerFolder: Int = 4096, nameTemplate: String = "") {
        self.nameTemplate = nameTemplate
        self.template = template
        self.namePattern = namePattern
        self.fallbackFolder = fallbackFolder
        self.numberDuplicates = numberDuplicates
        self.maxPerFolder = maxPerFolder
    }
}

public enum OrganizePlanner {
    public struct Plan: Sendable {
        public var items: [OrganizeItem]
        /// A problem with the layout itself (e.g. an invalid name pattern), if any.
        public var error: String?

        public init(items: [OrganizeItem], error: String? = nil) {
            self.items = items
            self.error = error
        }

        public var notReadCount: Int { items.filter { $0.status == .notRead }.count }

        /// Destination folders (relative to `root`) and how many files go into each.
        public func folders(relativeTo root: URL) -> [(path: String, count: Int)] {
            let moving = items.filter(\.status.willMove)
            let grouped = Dictionary(grouping: moving) { relativePath($0.destination.deletingLastPathComponent(), root) }
            return grouped.map { ($0.key, $0.value.count) }
                .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        }
    }

    public static func relativePath(_ url: URL, _ root: URL) -> String {
        let p = url.standardizedFileURL.path, r = root.standardizedFileURL.path
        if p == r { return "." }
        return p.hasPrefix(r + "/") ? String(p.dropFirst(r.count + 1)) : p
    }

    /// Lists the visible items in a folder (empty if it doesn't exist). Replaceable in tests.
    public typealias FolderLister = @Sendable (URL) -> [String]

    public static let diskLister: FolderLister = { dir in
        ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).filter { !$0.hasPrefix(".") }
    }

    /// Works out where each file goes under `root`.
    /// `unread`: files whose details (EXIF, video) haven't been read yet; if the layout needs them they're
    /// marked `.notRead` rather than sent to the fallback folder.
    public static func plan(files: [URL], root: URL, options: OrganizeOptions, metadata: [URL: FileMetadata],
                            unread: Set<URL> = [], lister: FolderLister = diskLister) -> Plan {
        var regex: NSRegularExpression?
        if !options.namePattern.isEmpty {
            do { regex = try NSRegularExpression(pattern: options.namePattern, options: [.caseInsensitive]) }
            catch { return Plan(items: [], error: "The name pattern isn’t a valid regular expression") }
        }
        // "." means "this folder" (used to only split a big folder into numbered subfolders).
        let components = options.template.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
            .filter { $0.trimmingCharacters(in: .whitespaces) != "." }
        if components.isEmpty && options.template.trimmingCharacters(in: .whitespaces) != "." {
            return Plan(items: [], error: "Enter a folder layout, e.g. {taken:yyyy}/{taken:MM}")
        }
        if let bad = FS.validateName(options.fallbackFolder) { return Plan(items: [], error: "Fallback folder: \(bad)") }
        if let problem = NameTemplate.problem(in: options.template) { return Plan(items: [], error: problem) }

        let needsDetails = NameTemplate.needsDetails(options.template) || NameTemplate.needsDetails(options.nameTemplate)
        let nameTemplate = options.nameTemplate.trimmingCharacters(in: .whitespaces)
        // First: the folder each file belongs in.
        var placed: [Placed] = files.enumerated().map { index, url in
            if needsDetails && unread.contains(url) { return Placed(url: url, dir: nil, status: .notRead, name: url.lastPathComponent) }
            let name = url.lastPathComponent
            let ext = url.pathExtension
            let base = ext.isEmpty ? name : String(name.dropLast(ext.count + 1))
            var groups: [String] = []
            if let regex, let match = regex.firstMatch(in: base, range: NSRange(base.startIndex..., in: base)) {
                groups = (1..<match.numberOfRanges).map { i in
                    Range(match.range(at: i), in: base).map { String(base[$0]) } ?? ""
                }
            }
            let ctx = NameTemplate.Context(metadata: metadata[url], name: base, ext: ext, number: index + 1, groups: groups)
            var folders: [String] = []
            var missing: [String] = []
            for component in components {
                let r = NameTemplate.render(component, ctx)
                missing += r.missing
                let folder = r.text.trimmingCharacters(in: .whitespaces)
                if !folder.isEmpty { folders.append(folder) }
            }
            var status: OrganizeStatus = .ok
            if !missing.isEmpty {
                folders = [options.fallbackFolder]
                status = .fallback(Array(Set(missing)).sorted().joined(separator: ", "))
            }
            if let bad = folders.lazy.compactMap(FS.validateName).first {
                return Placed(url: url, dir: nil, status: .invalid(bad), name: name)
            }
            // New file name, if asked for and the file has what it needs; otherwise its own name.
            var newName = name
            if !nameTemplate.isEmpty {
                let r = NameTemplate.render(nameTemplate, ctx)
                let renamed = ext.isEmpty ? r.text : r.text + "." + ext
                if r.missing.isEmpty, !r.text.isEmpty, FS.validateName(renamed) == nil { newName = renamed }
            }
            return Placed(url: url, dir: folders.reduce(root) { $0.appendingPathComponent($1, isDirectory: true) }.standardizedFileURL,
                          status: status, name: newName)
        }
        // Then: folders that would get too full are split into 001, 002…
        if options.maxPerFolder > 0 { split(&placed, limit: options.maxPerFolder, lister: lister) }

        var items: [OrganizeItem] = placed.map { p in
            guard let dir = p.dir else { return OrganizeItem(source: p.url, destination: p.url, status: p.status) }
            let destination = dir.appendingPathComponent(p.name)
            if destination.standardizedFileURL == p.url.standardizedFileURL {
                return OrganizeItem(source: p.url, destination: p.url, status: .unchanged)
            }
            return OrganizeItem(source: p.url, destination: destination, status: p.status)
        }
        if options.numberDuplicates { numberDuplicates(&items) }
        return Plan(items: items, error: nil)
    }

    struct Placed {
        var url: URL
        var dir: URL?
        var status: OrganizeStatus
        /// The file's name at its destination.
        var name: String
    }

    /// "001", "002"… (more digits past 999).
    public static func numberedFolderName(_ n: Int) -> String { String(format: "%03d", n) }

    static func numberedIndex(_ name: String) -> Int? {
        name.count >= 3 && name.allSatisfy(\.isASCII) && name.allSatisfy(\.isNumber) ? Int(name) : nil
    }

    /// For every destination folder that would hold more than `limit` items (counting what's already there),
    /// the files going into it are put into numbered subfolders 001, 002… of at most `limit` each, continuing
    /// after any numbered subfolders that already exist. Files already inside a numbered subfolder stay put.
    static func split(_ placed: inout [Placed], limit: Int, lister: FolderLister) {
        // Folders are compared by path ("/a/b"), never by URL: "/a/b" and "/a/b/" are the same folder.
        func key(_ url: URL) -> String { url.standardizedFileURL.path }
        func parentKey(_ url: URL) -> String { key(url.deletingLastPathComponent()) }
        let byDir = Dictionary(grouping: placed.indices.filter { placed[$0].dir != nil }) { key(placed[$0].dir!) }
        // Names in each source folder that are part of this plan (moving out, or explicitly kept).
        var fromDir: [String: Set<String>] = [:]
        for p in placed where p.dir != nil {
            fromDir[parentKey(p.url), default: []].insert(p.url.lastPathComponent)
        }
        for (dirPath, indices) in byDir {
            let dir = URL(fileURLWithPath: dirPath, isDirectory: true)
            let onDisk = lister(dir)
            let ours = fromDir[dirPath] ?? []
            let staying = onDisk.filter { !ours.contains($0) && numberedIndex($0) == nil }.count
            // Files already sitting in one of this folder's numbered subfolders don't need to move.
            let alreadyNumbered = indices.filter { i in
                let parent = placed[i].url.deletingLastPathComponent()
                return parentKey(parent) == dirPath && numberedIndex(parent.lastPathComponent) != nil
            }
            let incoming = indices.filter { !alreadyNumbered.contains($0) }
            guard staying + incoming.count + alreadyNumbered.count > limit else { continue }

            for i in alreadyNumbered { placed[i].dir = placed[i].url.deletingLastPathComponent() }
            let existing = onDisk.compactMap(numberedIndex).sorted()
            var current = existing.last ?? 1
            func count(_ n: Int) -> Int {
                let sub = dir.appendingPathComponent(numberedFolderName(n), isDirectory: true)
                let leaving = fromDir[key(sub)] ?? []
                let stay = lister(sub).filter { !leaving.contains($0) }.count
                return stay + alreadyNumbered.filter { key(placed[$0].dir!) == key(sub) }.count
            }
            var used = count(current)
            for i in incoming {
                while used >= limit {
                    current += 1
                    used = count(current)
                }
                placed[i].dir = dir.appendingPathComponent(numberedFolderName(current), isDirectory: true)
                used += 1
            }
        }
    }

    /// Two files heading for the same name in the same folder: "a.jpg", "a 2.jpg"…
    static func numberDuplicates(_ items: inout [OrganizeItem]) {
        var taken = Set<String>()
        for i in items.indices where !items[i].status.willMove {
            taken.insert(items[i].source.standardizedFileURL.path.lowercased())
        }
        for i in items.indices where items[i].status.willMove {
            var dest = items[i].destination
            var n = 2
            while taken.contains(dest.path.lowercased()) {
                let original = items[i].destination
                let ext = original.pathExtension
                let base = ext.isEmpty ? original.lastPathComponent : original.deletingPathExtension().lastPathComponent
                let name = ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)"
                dest = original.deletingLastPathComponent().appendingPathComponent(name)
                n += 1
            }
            items[i].destination = dest
            taken.insert(dest.path.lowercased())
        }
    }
}
