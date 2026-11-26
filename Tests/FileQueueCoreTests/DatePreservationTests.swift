import Foundation
import Testing
@testable import FileQueueCore

/// Copies and moves must keep each item's original modified (and created) date —
/// for files, folders at every level, and symlinks.
@Suite("Dates are preserved", .serialized)
struct DatePreservationTests {
    static let modified = Date(timeIntervalSince1970: 1_500_000_000) // 2017-07-14
    static let created = Date(timeIntervalSince1970: 1_400_000_000)  // 2014-05-13

    /// Builds `album/` with a file, a nested folder with a file, and a symlink — all back-dated.
    /// Folders are dated last, since adding children changes a folder's modified date.
    func makeTree(in dir: URL) throws -> URL {
        let fm = FileManager.default
        let album = dir.appendingPathComponent("album")
        try fm.createDirectory(at: album.appendingPathComponent("nested"), withIntermediateDirectories: true)
        try Data("photo".utf8).write(to: album.appendingPathComponent("a.jpg"))
        try Data("deep".utf8).write(to: album.appendingPathComponent("nested/b.jpg"))
        try fm.createSymbolicLink(atPath: album.appendingPathComponent("link").path, withDestinationPath: "a.jpg")
        for path in ["a.jpg", "nested/b.jpg", "nested", ""] {
            try fm.setAttributes([.modificationDate: Self.modified, .creationDate: Self.created],
                                 ofItemAtPath: album.appendingPathComponent(path).path)
        }
        setLinkDate(album.appendingPathComponent("link"), Self.modified)
        return album
    }

    func setLinkDate(_ url: URL, _ date: Date) {
        var times = [timeval(tv_sec: Int(date.timeIntervalSince1970), tv_usec: 0),
                     timeval(tv_sec: Int(date.timeIntervalSince1970), tv_usec: 0)]
        lutimes(url.path, &times)
    }

    func modifiedDate(_ url: URL) -> Date? { FS.stamp(url)?.modified }

    func createdDate(_ url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.creationDateKey]))?.creationDate
    }

    func expectDatesKept(_ album: URL, sourceLocation: SourceLocation = #_sourceLocation) {
        for path in ["", "a.jpg", "nested", "nested/b.jpg", "link"] {
            let item = album.appendingPathComponent(path)
            let label = path.isEmpty ? "album" : path
            #expect(modifiedDate(item) == Self.modified, "modified date of \(label)", sourceLocation: sourceLocation)
            if path != "link" {
                #expect(createdDate(item) == Self.created, "created date of \(label)", sourceLocation: sourceLocation)
            }
        }
    }

    @Test("Copy on the same disk")
    func copySameDisk() async throws {
        let s = try Sandbox(); defer { s.cleanup() }
        let album = try makeTree(in: s.dir("src"))
        let engine = await s.engine()
        try await engine.enqueue(.copy(sources: [album], destinationDir: try s.dir("dest")))
        await engine.waitUntilIdle()
        expectDatesKept(s.path("dest/album"))
        expectDatesKept(album) // the original is untouched too
    }

    @Test("Move on the same disk")
    func moveSameDisk() async throws {
        let s = try Sandbox(); defer { s.cleanup() }
        let album = try makeTree(in: s.dir("src"))
        let engine = await s.engine()
        try await engine.enqueue(.move(sources: [album], destinationDir: try s.dir("dest")))
        await engine.waitUntilIdle()
        expectDatesKept(s.path("dest/album"))
    }

    @Test("Copy and move to another disk")
    func crossDisk() async throws {
        guard let image = DiskImage(caseSensitive: false) else { return }
        defer { image.detach() }
        let s = try Sandbox(); defer { s.cleanup() }
        let engine = await s.engine()

        let copySource = try makeTree(in: s.dir("copy"))
        try await engine.enqueue(.copy(sources: [copySource], destinationDir: image.mountPoint))
        await engine.waitUntilIdle()
        expectDatesKept(image.mountPoint.appendingPathComponent("album"))

        let moveSource = try makeTree(in: s.dir("move"))
        let target = try FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                                 appropriateFor: image.mountPoint, create: true)
        try await engine.enqueue(.move(sources: [moveSource], destinationDir: target))
        await engine.waitUntilIdle()
        #expect(!FS.itemExists(moveSource))
        expectDatesKept(target.appendingPathComponent("album"))
    }
}
