import CryptoKit
import Foundation

/// Low-level file-system helpers. None of these follow symlinks.
public enum FS {
    public static func itemExists(_ url: URL) -> Bool {
        var st = stat()
        return lstat(url.path, &st) == 0
    }

    public static func isDirectory(_ url: URL) -> Bool {
        var st = stat()
        return lstat(url.path, &st) == 0 && (st.st_mode & S_IFMT) == S_IFDIR
    }

    public static func stamp(_ url: URL) -> FileStamp? {
        var st = stat()
        guard lstat(url.path, &st) == 0 else { return nil }
        let mtime = Date(timeIntervalSince1970: TimeInterval(st.st_mtimespec.tv_sec)
            + TimeInterval(st.st_mtimespec.tv_nsec) / 1_000_000_000)
        return FileStamp(device: Int64(st.st_dev), inode: UInt64(st.st_ino), modified: mtime)
    }

    /// True when both URLs name the same file on disk (e.g. a case-only rename).
    public static func sameFile(_ a: URL, _ b: URL) -> Bool {
        guard let sa = stamp(a), let sb = stamp(b) else { return false }
        return sa.device == sb.device && sa.inode == sb.inode
    }

    /// True if `url` still is the item described by `stamp` (or just exists, if no stamp was taken).
    public static func matches(_ url: URL, _ stamp: FileStamp?) -> Bool {
        guard let current = self.stamp(url) else { return false }
        guard let stamp else { return true }
        return stamp.matches(current)
    }

    /// `child` is `parent` itself or somewhere inside it.
    public static func isSameOrInside(_ child: URL, _ parent: URL) -> Bool {
        let c = child.standardizedFileURL.resolvingSymlinksInPath().path
        let p = parent.standardizedFileURL.resolvingSymlinksInPath().path
        return c == p || c.hasPrefix(p.hasSuffix("/") ? p : p + "/")
    }

    /// Logical size in bytes and number of non-directory items.
    public static func totalSize(_ url: URL) -> (bytes: Int64, files: Int) {
        var st = stat()
        guard lstat(url.path, &st) == 0 else { return (0, 0) }
        if (st.st_mode & S_IFMT) != S_IFDIR { return (Int64(st.st_size), 1) }
        var bytes: Int64 = 0
        var files = 0
        let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil, options: [], errorHandler: { _, _ in true })
        while let item = enumerator?.nextObject() as? URL {
            var s = stat()
            if lstat(item.path, &s) == 0, (s.st_mode & S_IFMT) != S_IFDIR {
                bytes += Int64(s.st_size)
                files += 1
            }
        }
        return (bytes, files)
    }

    /// "Report.pdf" → "Report 2.pdf", "Report 3.pdf", … (first free name).
    public static func uniqueURL(_ url: URL) -> URL {
        let dir = url.deletingLastPathComponent()
        let isPlainFolder = isDirectory(url) && !NSWorkspace_isPackage(url)
        let ext = isPlainFolder ? "" : url.pathExtension
        let base = ext.isEmpty ? url.lastPathComponent : url.deletingPathExtension().lastPathComponent
        var n = 2
        while true {
            let name = ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)"
            let candidate = dir.appendingPathComponent(name)
            if !itemExists(candidate) { return candidate }
            n += 1
        }
    }

    private static func NSWorkspace_isPackage(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isPackageKey]))?.isPackage ?? false
    }

    /// Returns a reason the name can't be used, or nil if it's valid on macOS.
    public static func validateName(_ name: String) -> String? {
        if name.isEmpty { return "Name is empty" }
        if name == "." || name == ".." { return "“\(name)” is reserved" }
        if name.contains("/") { return "Name can’t contain “/”" }
        if name.contains(":") { return "Name can’t contain “:”" }
        if name.contains("\0") { return "Name contains an invalid character" }
        if name.utf8.count > 255 { return "Name is too long" }
        return nil
    }

    /// Renames without ever overwriting an existing item.
    public static func renameExclusive(_ from: URL, _ to: URL) throws {
        if renamex_np(from.path, to.path, UInt32(RENAME_EXCL)) == 0 { return }
        var code = errno
        // Some file systems (exFAT, FAT, many network shares) don't support the no-overwrite flag.
        // Fall back to checking first, then a plain rename.
        if code == ENOTSUP || code == EINVAL {
            if itemExists(to) { throw FQError.destinationExists(to.path) }
            if rename(from.path, to.path) == 0 { return }
            code = errno
        }
        if code == EEXIST { throw FQError.destinationExists(to.path) }
        throw FQError.posix(code, from.path)
    }

    /// True if writing at `url` (or its nearest existing parent) is refused because the file system is
    /// read-only. Folders like /Applications are writable even though the system volume is read-only.
    public static func isOnReadOnlyFileSystem(_ url: URL) -> Bool {
        var probe = url.standardizedFileURL
        while !itemExists(probe), probe.path != "/" { probe = probe.deletingLastPathComponent() }
        var fs = statfs()
        guard statfs(probe.path, &fs) == 0 else { return false }
        guard (fs.f_flags & UInt32(MNT_RDONLY)) != 0 else { return false }
        return access(probe.path, W_OK) != 0 && errno == EROFS
    }

    /// Hidden name an item is copied to before it's complete: ".<name>.<job>.fqpart".
    /// Long names are shortened so the result stays within the 255-byte limit.
    public static func partialSuffix(jobID: UUID) -> String {
        ".\(jobID.uuidString.prefix(8).lowercased()).fqpart"
    }

    public static func partialURL(for destination: URL, jobID: UUID) -> URL {
        let suffix = partialSuffix(jobID: jobID)
        var name = destination.lastPathComponent
        while ("." + name + suffix).utf8.count > 255 { name.removeLast() }
        return destination.deletingLastPathComponent().appendingPathComponent("." + name + suffix)
    }

    /// Like `renameExclusive`, but handles case-only renames ("a.txt" → "A.txt")
    /// on case-insensitive disks by going through a temporary name.
    public static func renameAllowingCaseChange(_ from: URL, _ to: URL) throws {
        if itemExists(to) && sameFile(from, to) {
            let temp = from.deletingLastPathComponent().appendingPathComponent(".fq-\(UUID().uuidString).tmp")
            try renameExclusive(from, temp)
            do {
                try renameExclusive(temp, to)
            } catch {
                try? renameExclusive(temp, from)
                throw error
            }
        } else {
            try renameExclusive(from, to)
        }
    }

    /// Gives every item in `destination` the created and modified dates of its counterpart in
    /// `source` (exact to the nanosecond, symlinks included). Children are done before their
    /// parent folder, because changing anything inside a folder updates the folder's own date.
    public static func copyDates(from source: URL, to destination: URL) {
        var relativePaths: [String] = []
        if isDirectory(source) {
            let basePath = source.standardizedFileURL.path
            let enumerator = FileManager.default.enumerator(at: source, includingPropertiesForKeys: nil, options: [], errorHandler: { _, _ in true })
            while let item = enumerator?.nextObject() as? URL {
                relativePaths.append(String(item.standardizedFileURL.path.dropFirst(basePath.count + 1)))
            }
        }
        // The enumerator lists parents before children, so reversed order is children first.
        for path in relativePaths.reversed() {
            copyItemDates(from: source.appendingPathComponent(path), to: destination.appendingPathComponent(path))
        }
        copyItemDates(from: source, to: destination)
    }

    /// An item's created and modified times, read now to apply later (e.g. after a move has emptied the folder).
    public struct ItemTimes: Sendable { let created: timespec; let modified: timespec }

    public static func times(of url: URL) -> ItemTimes? {
        var st = stat()
        guard lstat(url.path, &st) == 0 else { return nil }
        return ItemTimes(created: st.st_birthtimespec, modified: st.st_mtimespec)
    }

    public static func setTimes(_ times: ItemTimes, on destination: URL) {
        var request = attrlist()
        request.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        request.commonattr = attrgroup_t(ATTR_CMN_CRTIME) | attrgroup_t(ATTR_CMN_MODTIME)
        var buffer = [times.created, times.modified]
        _ = buffer.withUnsafeMutableBytes { raw in
            setattrlist(destination.path, &request, raw.baseAddress, raw.count, UInt32(FSOPT_NOFOLLOW))
        }
    }

    static func copyItemDates(from source: URL, to destination: URL) {
        var st = stat()
        guard lstat(source.path, &st) == 0 else { return }
        var request = attrlist()
        request.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        // Buffer order follows the attribute bits: creation time (0x200), then modification time (0x400).
        request.commonattr = attrgroup_t(ATTR_CMN_CRTIME) | attrgroup_t(ATTR_CMN_MODTIME)
        var times = [st.st_birthtimespec, st.st_mtimespec]
        _ = times.withUnsafeMutableBytes { buffer in
            setattrlist(destination.path, &request, buffer.baseAddress, buffer.count, UInt32(FSOPT_NOFOLLOW))
        }
    }

    /// A readable message for an error, including the underlying system reason
    /// (e.g. "The file “100D5100” couldn’t be opened. (Input/output error)").
    public static func describe(_ error: Error) -> String {
        if let fq = error as? FQError { return fq.localizedDescription }
        let ns = error as NSError
        var message = ns.localizedDescription
        var underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError
        if ns.domain == NSPOSIXErrorDomain { underlying = ns }
        if let u = underlying, u.domain == NSPOSIXErrorDomain {
            let reason = String(cString: strerror(Int32(u.code)))
            if !message.contains(reason) { message += " (\(reason))" }
        }
        return message
    }

    /// The disk itself failed to read or write (damage, bad sectors, disconnected), rather than e.g. permissions.
    public static func isDiskError(_ error: Error) -> Bool {
        let ns = error as NSError
        let posix = ns.domain == NSPOSIXErrorDomain ? ns : ns.userInfo[NSUnderlyingErrorKey] as? NSError
        if let p = posix, p.domain == NSPOSIXErrorDomain { return [EIO, ENXIO, ENODEV].contains(Int32(p.code)) }
        if case let .posix(code, _)? = error as? FQError { return [EIO, ENXIO, ENODEV].contains(code) }
        return false
    }

    /// A real folder (not a package like .app) — the kind that can be merged into another.
    public static func isMergeableFolder(_ url: URL) -> Bool {
        guard isDirectory(url) else { return false }
        return (try? url.resourceValues(forKeys: [.isPackageKey]))?.isPackage != true
    }

    /// Is `existing` already a copy of `source`?
    /// - Files: same size, and either the same modified date (at the precision the disks store) or,
    ///   if the dates differ, the same bytes. (Some disks can't keep a date exactly — e.g. exFAT is off by
    ///   a day for dates after 2100 — and some copy tools don't keep dates.) With `checksums`, the bytes
    ///   are always compared.
    /// - Symlinks: same target. Packages (e.g. .app): compared as a whole.
    public static func sameContents(_ source: URL, _ existing: URL, checksums: Bool) throws -> Bool {
        var a = stat(), b = stat()
        guard lstat(source.path, &a) == 0, lstat(existing.path, &b) == 0 else { return false }
        let typeA = a.st_mode & S_IFMT, typeB = b.st_mode & S_IFMT
        guard typeA == typeB else { return false }
        if typeA == S_IFLNK {
            let fm = FileManager.default
            return (try? fm.destinationOfSymbolicLink(atPath: source.path)) == (try? fm.destinationOfSymbolicLink(atPath: existing.path))
        }
        let tolerance = max(timestampResolution(source), timestampResolution(existing))
        func seconds(_ t: timespec) -> Double { Double(t.tv_sec) + Double(t.tv_nsec) / 1_000_000_000 }
        let sameDate = abs(seconds(a.st_mtimespec) - seconds(b.st_mtimespec)) <= tolerance
        if typeA == S_IFDIR {
            // Packages (e.g. .app) are compared as a whole.
            guard sameDate else { return false }
            return try contentsMatch(source, existing, checksums: checksums)
        }
        guard typeA == S_IFREG, a.st_size == b.st_size else { return false }
        if sameDate && !checksums { return true }
        return try sha256(source) == sha256(existing)
    }

    /// A fast "is this the same file?" that ignores dates: same size, then the bytes are compared —
    /// all of them for small files, or the start, the end and evenly spaced samples for large ones.
    /// Folders (packages) fall back to comparing sizes; symlinks compare their targets.
    public static func quickSameContents(_ a: URL, _ b: URL) throws -> Bool {
        var sa = stat(), sb = stat()
        guard lstat(a.path, &sa) == 0, lstat(b.path, &sb) == 0 else { return false }
        let typeA = sa.st_mode & S_IFMT
        guard typeA == sb.st_mode & S_IFMT else { return false }
        if typeA != S_IFREG { return try sameContents(a, b, checksums: false) }
        guard sa.st_size == sb.st_size else { return false }
        let ha = try FileHandle(forReadingFrom: a), hb = try FileHandle(forReadingFrom: b)
        defer { try? ha.close(); try? hb.close() }
        for range in sampleRanges(size: UInt64(sa.st_size)) {
            try ha.seek(toOffset: range.lowerBound); try hb.seek(toOffset: range.lowerBound)
            let count = Int(range.upperBound - range.lowerBound)
            guard try ha.read(upToCount: count) == hb.read(upToCount: count) else { return false }
        }
        return true
    }

    /// The parts of a file a quick check reads: everything if it's small (up to 1.5 MB), otherwise
    /// 256 KB at each end (where most formats keep headers and indexes) and 16 evenly spaced 64 KB blocks.
    public static func sampleRanges(size: UInt64) -> [Range<UInt64>] {
        let block: UInt64 = 64 << 10, edge = block * 4, samples: UInt64 = 16
        if size <= block * 24 {
            return stride(from: UInt64(0), to: size, by: Int(1 << 20)).map { $0..<min(size, $0 + (1 << 20)) }
        }
        var ranges = [0..<edge]
        let span = size - 2 * edge - block
        for i in 0..<samples {
            let offset = edge + span * i / (samples - 1)
            ranges.append(offset..<(offset + block))
        }
        ranges.append((size - edge)..<size)
        return ranges
    }

    /// Whether `sampleRanges` covers the whole file (so a quick check is as good as a full one).
    public static func quickCheckIsComplete(size: UInt64) -> Bool { size <= (64 << 10) * 24 }

    /// How precisely the file system at `url` stores modified times, in seconds.
    /// APFS and NTFS keep (near) nanoseconds, exFAT 10 ms, HFS+ 1 s, FAT 2 s. Unknown/network: 2 s.
    static func timestampResolution(_ url: URL) -> Double {
        var fs = statfs()
        guard statfs(url.path, &fs) == 0 else { return 2 }
        let type = withUnsafeBytes(of: fs.f_fstypename) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }.lowercased()
        switch type {
        case "apfs": return 0.000_001
        case "ntfs", "ufsd_ntfs", "tuxera_ntfs": return 0.000_001
        case "exfat": return 0.01
        case "hfs": return 1
        default: return 2 // msdos (FAT), smbfs, nfs, afpfs, …
        }
    }

    /// Recursively compares sizes (and optionally SHA-256) of two items.
    public static func contentsMatch(_ a: URL, _ b: URL, checksums: Bool) throws -> Bool {
        guard totalSize(a) == totalSize(b) else { return false }
        guard checksums else { return true }
        if !isDirectory(a) { return try sha256(a) == sha256(b) }
        let enumerator = FileManager.default.enumerator(at: a, includingPropertiesForKeys: [.isRegularFileKey], options: [], errorHandler: { _, _ in true })
        let basePath = a.standardizedFileURL.path
        while let item = enumerator?.nextObject() as? URL {
            guard (try? item.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
            let relative = String(item.standardizedFileURL.path.dropFirst(basePath.count + 1))
            let counterpart = b.appendingPathComponent(relative)
            if try sha256(item) != sha256(counterpart) { return false }
        }
        return true
    }

    static func sha256(_ url: URL) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return Data(hasher.finalize())
    }
}

// MARK: - Trash

public protocol Trashing: Sendable {
    /// Moves the item to the Trash and returns where it ended up.
    func trash(_ url: URL) throws -> URL
}

public struct SystemTrash: Trashing {
    public init() {}
    public func trash(_ url: URL) throws -> URL {
        var result: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &result)
        return (result as URL?) ?? url
    }
}

/// Moves items into a folder instead of the real Trash. Used by tests.
public struct FolderTrash: Trashing {
    public let folder: URL
    public init(folder: URL) { self.folder = folder }
    public func trash(_ url: URL) throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var target = folder.appendingPathComponent(url.lastPathComponent)
        if FS.itemExists(target) { target = FS.uniqueURL(target) }
        try FileManager.default.moveItem(at: url, to: target)
        return target
    }
}
