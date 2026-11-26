import Foundation

/// Finds folders that hold nothing worth keeping, so they can be moved to the Trash.
///
/// A folder counts as empty when it holds nothing, only system clutter (`.DS_Store`, `Thumbs.db`,
/// `desktop.ini`, `._` AppleDouble files, `.localized`), or only folders that are empty themselves.
/// Only the outermost empty folder of each empty tree is returned, never `root` itself.
/// Packages (`.app`, `.photoslibrary`…), symlinks and hidden folders are never treated as empty,
/// and anything else inside a folder — including hidden files — keeps it.
public enum EmptyFolderFinder {
    /// Files that don't count as content.
    public static func isClutter(_ name: String) -> Bool {
        let lower = name.lowercased()
        return [".ds_store", "thumbs.db", "desktop.ini", ".localized", "ehthumbs.db"].contains(lower)
            || name.hasPrefix("._")
    }

    public struct Result: Sendable {
        /// Outermost empty folders, in path order.
        public var folders: [URL] = []
        /// Folders looked at.
        public var scanned = 0
        /// Folders that couldn't be read (left alone).
        public var unreadable: [URL] = []
    }

    public static func find(in root: URL, isCancelled: @Sendable () -> Bool = { false },
                            progress: @Sendable (Int) -> Void = { _ in }) -> Result {
        var result = Result()
        let base = root.standardizedFileURL
        _ = isEmpty(base, isRoot: true, result: &result, isCancelled: isCancelled, progress: progress)
        result.folders.sort { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        return result
    }

    /// True if `folder` is empty in the sense above. Empty children are collected into `result`
    /// unless this folder is empty too (then the caller collects it instead).
    private static func isEmpty(_ folder: URL, isRoot: Bool, result: inout Result,
                                isCancelled: @Sendable () -> Bool, progress: @Sendable (Int) -> Void) -> Bool {
        if isCancelled() { return false }
        result.scanned += 1
        if result.scanned % 200 == 0 { progress(result.scanned) }
        let names: [String]
        do { names = try FileManager.default.contentsOfDirectory(atPath: folder.path) } catch {
            result.unreadable.append(folder)
            return false
        }
        var empty = true
        var emptyChildren: [URL] = []
        for name in names {
            if isClutter(name) { continue }
            let child = folder.appendingPathComponent(name)
            guard isPlainFolder(child), !name.hasPrefix(".") else { empty = false; continue }
            if isEmpty(child, isRoot: false, result: &result, isCancelled: isCancelled, progress: progress) {
                emptyChildren.append(child)
            } else {
                empty = false
            }
        }
        if isCancelled() { return false }
        if empty && !isRoot { return true }
        result.folders.append(contentsOf: emptyChildren)
        return false
    }

    /// A real folder (not a symlink or package).
    static func isPlainFolder(_ url: URL) -> Bool {
        guard let v = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isPackageKey]) else { return false }
        return v.isDirectory == true && v.isSymbolicLink != true && v.isPackage != true
    }

    /// Checks again just before trashing (something may have been added since the scan).
    public static func isStillEmpty(_ folder: URL) -> Bool {
        guard isPlainFolder(folder) else { return false }
        var r = Result()
        return isEmpty(folder.standardizedFileURL, isRoot: false, result: &r, isCancelled: { false }, progress: { _ in })
    }
}
