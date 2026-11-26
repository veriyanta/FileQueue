import DiskArbitration
import Foundation

public protocol DiskResolving: Sendable {
    /// The disk that holds `url` (or, if `url` doesn't exist yet, its nearest existing parent).
    func disk(for url: URL) throws -> DiskInfo
}

/// Groups volumes by physical disk using DiskArbitration, so two APFS volumes in the same
/// container (e.g. "Macintosh HD" and "Macintosh HD - Data") share one lane.
/// Network and other volumes without a BSD device fall back to their volume UUID or mount path.
public struct SystemDiskResolver: DiskResolving {
    public init() {}

    /// A disk's details are the same for every file on it, and asking DiskArbitration is slow,
    /// so they're remembered per mounted volume for a short while (disks can be ejected/remounted).
    private final class Cache: @unchecked Sendable {
        let lock = NSLock()
        var entries: [String: (info: DiskInfo, time: Date)] = [:]
    }
    private static let cache = Cache()

    public func disk(for url: URL) throws -> DiskInfo {
        var probe = url.standardizedFileURL
        while !FS.itemExists(probe) {
            let parent = probe.deletingLastPathComponent()
            if parent.path == probe.path { throw FQError.diskUnavailable(url.path) }
            probe = parent
        }
        let volumeURL = (try probe.resourceValues(forKeys: [.volumeURLKey])).volume ?? URL(fileURLWithPath: "/")
        let cacheKey = volumeURL.path
        if let hit = Self.cache.lock.withLock({ Self.cache.entries[cacheKey] }), Date().timeIntervalSince(hit.time) < 30 {
            return hit.info
        }
        let info = try describe(volumeURL)
        Self.cache.lock.withLock { Self.cache.entries[cacheKey] = (info, Date()) }
        return info
    }

    private func describe(_ volumeURL: URL) throws -> DiskInfo {
        let keys: Set<URLResourceKey> = [
            .volumeUUIDStringKey, .volumeNameKey,
            .volumeLocalizedNameKey, .volumeSupportsCaseSensitiveNamesKey,
            .volumeIsReadOnlyKey, .volumeTypeNameKey,
        ]
        let values = try volumeURL.resourceValues(forKeys: keys)
        let id: String
        if let bsd = Self.wholeDiskBSDName(volumeURL: volumeURL) {
            id = "bsd:\(bsd)"
        } else if let uuid = values.volumeUUIDString {
            id = "uuid:\(uuid)"
        } else {
            id = "path:\(volumeURL.path)"
        }
        let name = values.volumeLocalizedName ?? values.volumeName ?? volumeURL.lastPathComponent
        return DiskInfo(
            id: DiskID(id), name: name, volumePath: volumeURL.path,
            isCaseSensitive: values.volumeSupportsCaseSensitiveNames ?? false,
            isReadOnly: values.volumeIsReadOnly ?? false,
            fileSystem: values.volumeTypeName
        )
    }

    static func wholeDiskBSDName(volumeURL: URL) -> String? {
        guard let session = DASessionCreate(kCFAllocatorDefault),
              let disk = DADiskCreateFromVolumePath(kCFAllocatorDefault, session, volumeURL as CFURL),
              let whole = DADiskCopyWholeDisk(disk),
              let bsd = DADiskGetBSDName(whole)
        else { return nil }
        return String(cString: bsd)
    }
}
