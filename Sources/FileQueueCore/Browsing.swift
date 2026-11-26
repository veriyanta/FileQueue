import Foundation

/// One row in a folder browser.
public struct DirectoryEntry: Identifiable, Hashable, Sendable {
    public let url: URL
    public let name: String
    /// A folder you can open (not a package like `.app`).
    public let isFolder: Bool
    public let isPackage: Bool
    public let isSymlink: Bool
    public let isHidden: Bool
    public let size: Int64?
    public let modified: Date?
    public let created: Date?
    /// The file type as Finder shows it in its Kind column ("JPEG image", "Folder", …).
    public let kind: String

    public var id: URL { url }

    // Non-optional values for sorting table columns.
    public var sortSize: Int64 { isFolder ? -1 : (size ?? 0) }
    public var sortModified: Date { modified ?? .distantPast }
    /// Kind, then extension, so e.g. .jpg and .jpeg group together inside "JPEG image".
    public var sortKind: String { kind + "\u{1}" + url.pathExtension.lowercased() }

    public init(url: URL, name: String, isFolder: Bool, isPackage: Bool, isSymlink: Bool, isHidden: Bool,
                size: Int64?, modified: Date?, created: Date?, kind: String? = nil) {
        self.url = url
        self.name = name
        self.isFolder = isFolder
        self.isPackage = isPackage
        self.isSymlink = isSymlink
        self.isHidden = isHidden
        self.size = size
        self.modified = modified
        self.created = created
        self.kind = kind ?? DirectoryEntry.fallbackKind(name: name, isFolder: isFolder)
    }

    static func fallbackKind(name: String, isFolder: Bool) -> String {
        if isFolder { return "Folder" }
        let ext = (name as NSString).pathExtension
        return ext.isEmpty ? "Document" : ext.uppercased() + " file"
    }
}

public enum DirectoryLister {
    static let keys: [URLResourceKey] = [
        .isDirectoryKey, .isPackageKey, .isSymbolicLinkKey, .isHiddenKey,
        .fileSizeKey, .contentModificationDateKey, .creationDateKey, .localizedTypeDescriptionKey,
    ]

    /// Lists a folder's contents (not recursive). Hidden items are left out unless asked for.
    public static func list(_ folder: URL, showHidden: Bool = false) throws -> [DirectoryEntry] {
        let options: FileManager.DirectoryEnumerationOptions = showHidden ? [] : [.skipsHiddenFiles]
        let urls = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys, options: options)
        return urls.map { url in
            let v = try? url.resourceValues(forKeys: Set(keys))
            let isDirectory = v?.isDirectory ?? false
            let isPackage = v?.isPackage ?? false
            return DirectoryEntry(
                url: url.standardizedFileURL,
                name: url.lastPathComponent,
                isFolder: isDirectory && !isPackage,
                isPackage: isPackage,
                isSymlink: v?.isSymbolicLink ?? false,
                isHidden: v?.isHidden ?? false,
                size: isDirectory && !isPackage ? nil : v?.fileSize.map(Int64.init),
                modified: v?.contentModificationDate,
                created: v?.creationDate,
                kind: v?.localizedTypeDescription
            )
        }
    }

    /// Folders first, then everything else, each group in the given order.
    public static func sorted(_ entries: [DirectoryEntry], by comparators: [KeyPathComparator<DirectoryEntry>]) -> [DirectoryEntry] {
        // Rows that tie (same kind, same date…) fall back to name order, like Finder.
        let byName = KeyPathComparator(\DirectoryEntry.name, comparator: .localizedStandard)
        let all = comparators.isEmpty ? [] : comparators + (comparators.contains { $0.keyPath == \DirectoryEntry.name } ? [] : [byName])
        let ordered = all.isEmpty ? entries : entries.sorted(using: all)
        return ordered.filter(\.isFolder) + ordered.filter { !$0.isFolder }
    }

    /// The folder and each parent up to `/`, nearest first.
    /// (Stops at "/" explicitly: `URL.deletingLastPathComponent()` on "/" gives "/..", not "/".)
    public static func ancestors(of folder: URL) -> [URL] {
        var result: [URL] = []
        var url = folder.standardizedFileURL
        while result.count < 256 {
            result.append(url)
            if url.path == "/" || url.path.isEmpty { break }
            url = url.deletingLastPathComponent().standardizedFileURL
        }
        return result
    }

    /// "untitled folder", "untitled folder 2", … — the first name not taken in `folder`.
    public static func newFolderURL(in folder: URL, baseName: String = "untitled folder") -> URL {
        let first = folder.appendingPathComponent(baseName)
        return FS.itemExists(first) ? FS.uniqueURL(first) : first
    }
}

/// A mounted volume, for the sidebar.
public struct VolumeInfo: Identifiable, Hashable, Sendable {
    public let url: URL
    public let name: String
    public let isInternal: Bool
    public let isEjectable: Bool
    public let isNetwork: Bool
    public let isReadOnly: Bool
    public var id: URL { url }

    public var symbolName: String {
        if isNetwork { return "server.rack" }
        if isInternal { return "internaldrive" }
        return "externaldrive"
    }

    /// Visible, browsable volumes: the startup disk first, then the rest by name.
    public static func mounted() -> [VolumeInfo] {
        let keys: [URLResourceKey] = [
            .volumeLocalizedNameKey, .volumeIsInternalKey, .volumeIsEjectableKey,
            .volumeIsRemovableKey, .volumeIsLocalKey, .volumeIsBrowsableKey, .volumeIsRootFileSystemKey,
            .volumeIsReadOnlyKey,
        ]
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        let volumes: [(VolumeInfo, Bool)] = urls.compactMap { url in
            let v = try? url.resourceValues(forKeys: Set(keys))
            guard v?.volumeIsBrowsable != false else { return nil }
            let isLocal = v?.volumeIsLocal ?? true
            let info = VolumeInfo(
                url: url,
                name: v?.volumeLocalizedName ?? url.lastPathComponent,
                isInternal: (v?.volumeIsInternal ?? false) && isLocal,
                isEjectable: (v?.volumeIsEjectable ?? false) || (v?.volumeIsRemovable ?? false) || !isLocal,
                isNetwork: !isLocal,
                isReadOnly: (v?.volumeIsReadOnly ?? false) && !(v?.volumeIsRootFileSystem ?? false)
            )
            return (info, v?.volumeIsRootFileSystem ?? (url.path == "/"))
        }
        return volumes.sorted { a, b in
            if a.1 != b.1 { return a.1 }
            return a.0.name.localizedStandardCompare(b.0.name) == .orderedAscending
        }.map(\.0)
    }
}
