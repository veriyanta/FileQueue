import Foundation
import Testing
@testable import FileQueueCore

/// Copying a folder that's already (partly) at the destination only copies what's missing.
@Suite("Merging folders", .serialized)
struct MergeTests {
    /// src/album: a.jpg, b.jpg, sub/c.jpg, sub2/d.jpg
    func makeAlbum(_ s: Sandbox) throws {
        try s.file("src/album/a.jpg", "AAAA")
        try s.file("src/album/b.jpg", "BBBB")
        try s.file("src/album/sub/c.jpg", "CCCC")
        try s.file("src/album/sub2/d.jpg", "DDDD")
    }

    func inode(_ url: URL) -> UInt64? { FS.stamp(url)?.inode }

    func copyAlbum(_ engine: QueueEngine, _ s: Sandbox, policy: ConflictPolicy = .merge, checksums: Bool = false) async throws -> Job {
        let id = try await engine.enqueue(.copy(sources: [s.path("src/album")], destinationDir: s.path("dest")),
                                          options: JobOptions(conflictPolicy: policy, verifyChecksums: checksums))
        await engine.waitUntilIdle()
        return try #require(await engine.job(id))
    }

    @Test("Re-copying a partly copied folder copies only what's missing")
    func resumesPartialCopy() async throws {
        let s = try Sandbox(); defer { s.cleanup() }
        try makeAlbum(s)
        try s.dir("dest")
        let asked = Counter()
        let engine = await s.engine(policy: { _ in asked.increment(); return ConflictDecision(.skip) })
        _ = try await copyAlbum(engine, s)

        // Simulate an interrupted earlier copy: some files and a whole subfolder never arrived.
        try FileManager.default.removeItem(at: s.path("dest/album/b.jpg"))
        try FileManager.default.removeItem(at: s.path("dest/album/sub2"))
        let aBefore = inode(s.path("dest/album/a.jpg"))
        let cBefore = inode(s.path("dest/album/sub/c.jpg"))

        let job = try await copyAlbum(engine, s)
        #expect(job.state == .completed)
        #expect(asked.value == 0) // nothing to ask: missing files copied, identical ones left alone
        #expect(s.read("dest/album/b.jpg") == "BBBB")
        #expect(s.read("dest/album/sub2/d.jpg") == "DDDD")
        #expect(inode(s.path("dest/album/a.jpg")) == aBefore) // not re-copied
        #expect(inode(s.path("dest/album/sub/c.jpg")) == cBefore)
        #expect(job.notes.contains("Merged “album”: 2 copied, 2 already there"))
        #expect(job.progress.completedBytes == job.progress.totalBytes)
    }

    @Test("A file that differs (e.g. half-copied) is asked about; Replace fixes it")
    func differentFileAsks() async throws {
        let s = try Sandbox(); defer { s.cleanup() }
        try makeAlbum(s)
        try s.file("dest/album/b.jpg", "BB") // half-finished copy from an older run
        let asked = Counter()
        let engine = await s.engine(policy: { request in
            asked.increment()
            #expect(request.canMerge == false)
            #expect(request.existing.lastPathComponent == "b.jpg")
            return ConflictDecision(.replace)
        })
        let job = try await copyAlbum(engine, s)
        #expect(asked.value == 1)
        #expect(s.read("dest/album/b.jpg") == "BBBB")
        #expect(s.read("_Trash/b.jpg") == "BB") // the old one went to the Trash
        #expect(job.state == .completed)
    }

    @Test("Skipping a different file keeps the existing one and says so")
    func skipDifferent() async throws {
        let s = try Sandbox(); defer { s.cleanup() }
        try makeAlbum(s)
        try s.file("dest/album/b.jpg", "older")
        let engine = await s.engine(policy: { _ in ConflictDecision(.skip) })
        let job = try await copyAlbum(engine, s)
        #expect(s.read("dest/album/b.jpg") == "older")
        #expect(job.notes.contains { $0.contains("1 skipped") })
    }

    @Test("With Ask, a folder conflict offers Merge")
    func askOffersMerge() async throws {
        let s = try Sandbox(); defer { s.cleanup() }
        try makeAlbum(s)
        try s.file("dest/album/a.jpg", "AAAA")
        let engine = await s.engine(policy: { request in
            // The folder is offered Merge; a.jpg (different date) is then asked about as a file.
            if request.existing.lastPathComponent == "album" {
                #expect(request.canMerge)
                return ConflictDecision(.merge)
            }
            #expect(!request.canMerge)
            return ConflictDecision(.skip)
        })
        _ = try await copyAlbum(engine, s, policy: .ask)
        #expect(s.read("dest/album/sub2/d.jpg") == "DDDD")
        #expect(!s.exists("dest/album 2"))
    }

    @Test("Skip / Keep Both on the whole folder still work")
    func otherFolderPolicies() async throws {
        let s = try Sandbox(); defer { s.cleanup() }
        try makeAlbum(s)
        try s.file("dest/album/a.jpg", "AAAA")
        let engine = await s.engine()
        _ = try await copyAlbum(engine, s, policy: .skip)
        #expect(!s.exists("dest/album/b.jpg"))
        _ = try await copyAlbum(engine, s, policy: .keepBoth)
        #expect(s.read("dest/album 2/b.jpg") == "BBBB")
    }

    @Test("An identical single file isn't copied again; Keep Both still duplicates on request")
    func identicalTopLevelFile() async throws {
        let s = try Sandbox(); defer { s.cleanup() }
        try s.file("src/a.txt", "same")
        try s.dir("dest")
        let engine = await s.engine()
        try await engine.enqueue(.copy(sources: [s.path("src/a.txt")], destinationDir: s.path("dest")))
        await engine.waitUntilIdle()
        let before = inode(s.path("dest/a.txt"))
        for policy in [ConflictPolicy.merge, .ask, .skip, .replace] {
            try await engine.enqueue(.copy(sources: [s.path("src/a.txt")], destinationDir: s.path("dest")), options: JobOptions(conflictPolicy: policy))
            await engine.waitUntilIdle()
        }
        #expect(inode(s.path("dest/a.txt")) == before)
        #expect(s.names("dest") == ["a.txt"])
        try await engine.enqueue(.copy(sources: [s.path("src/a.txt")], destinationDir: s.path("dest")), options: JobOptions(conflictPolicy: .keepBoth))
        await engine.waitUntilIdle()
        #expect(s.names("dest") == ["a 2.txt", "a.txt"])
    }

    @Test("With checksums on, same size and date but different content counts as different")
    func checksums() async throws {
        let s = try Sandbox(); defer { s.cleanup() }
        try s.file("src/album/a.jpg", "AAAA")
        try s.file("dest/album/a.jpg", "ZZZZ")
        let date = Date(timeIntervalSince1970: 1_600_000_000)
        for p in ["src/album/a.jpg", "dest/album/a.jpg"] {
            try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: s.path(p).path)
        }
        let asked = Counter()
        let engine = await s.engine(policy: { _ in asked.increment(); return ConflictDecision(.skip) })
        _ = try await copyAlbum(engine, s)
        #expect(asked.value == 0) // size + date match: treated as already there
        _ = try await copyAlbum(engine, s, checksums: true)
        #expect(asked.value == 1) // content differs: asked
    }

    @Test("Same size but a different date: the contents decide")
    func differentDateSameBytes() async throws {
        let s = try Sandbox(); defer { s.cleanup() }
        try s.file("src/album/same.mov", "identical bytes")
        try s.file("src/album/changed.mov", "version two!!!!")
        try s.file("dest/album/same.mov", "identical bytes")   // e.g. date stored a day off (exFAT, year 2100+)
        try s.file("dest/album/changed.mov", "version one!!!!") // same size, different content
        let longAgo = Date(timeIntervalSince1970: 1_000_000_000)
        for p in ["dest/album/same.mov", "dest/album/changed.mov"] {
            try FileManager.default.setAttributes([.modificationDate: longAgo], ofItemAtPath: s.path(p).path)
        }
        let asked = Counter()
        let engine = await s.engine(policy: { request in
            asked.increment()
            #expect(request.existing.lastPathComponent == "changed.mov")
            return ConflictDecision(.skip)
        })
        let job = try await copyAlbum(engine, s)
        #expect(asked.value == 1) // only the one whose bytes really differ
        #expect(job.notes.contains { $0.contains("1 already there") && $0.contains("1 skipped") })
    }

    @Test("Finder settings and exFAT metadata files don't cause questions or stray copies")
    func ignoresMetadataFiles() async throws {
        let s = try Sandbox(); defer { s.cleanup() }
        try s.file("src/album/a.jpg", "AAAA")
        try s.file("src/album/._a.jpg", "metadata")
        try s.file("src/album/.DS_Store", "source view settings")
        try s.file("dest/album/.DS_Store", "destination view settings")
        let asked = Counter()
        let engine = await s.engine(policy: { _ in asked.increment(); return ConflictDecision(.skip) })
        _ = try await copyAlbum(engine, s)
        #expect(asked.value == 0)
        #expect(s.read("dest/album/.DS_Store") == "destination view settings")
        #expect(!s.exists("dest/album/._a.jpg"))
        #expect(s.read("dest/album/a.jpg") == "AAAA")
    }

    @Test("Merged move: moves what's missing, trashes identical originals, leaves skipped ones; undo restores")
    func mergedMoveAndUndo() async throws {
        let s = try Sandbox(); defer { s.cleanup() }
        try s.file("src/album/a.jpg", "AAAA")
        try s.file("src/album/b.jpg", "BBBB")
        try s.file("src/album/c.jpg", "new C")
        try s.dir("dest")
        let engine = await s.engine(policy: { _ in ConflictDecision(.skip) })
        // a.jpg is already there (identical), c.jpg is there in a different version.
        try await engine.enqueue(.copy(sources: [s.path("src/album/a.jpg")], destinationDir: try s.dir("dest/album")))
        await engine.waitUntilIdle()
        try s.file("dest/album/c.jpg", "old C")

        let id = try await engine.enqueue(.move(sources: [s.path("src/album")], destinationDir: s.path("dest")))
        await engine.waitUntilIdle()
        #expect(try #require(await engine.job(id)).state == .completed)
        #expect(s.names("dest/album") == ["a.jpg", "b.jpg", "c.jpg"])
        #expect(s.read("dest/album/c.jpg") == "old C")        // skipped: kept as it was
        #expect(s.names("src/album") == ["c.jpg"])             // the skipped original stays put
        #expect(s.exists("_Trash/a.jpg"))                      // identical original: in the Trash, not deleted

        try await engine.undo(id)
        await engine.waitUntilIdle()
        #expect(s.names("src/album") == ["a.jpg", "b.jpg", "c.jpg"])
        #expect(s.names("dest/album") == ["a.jpg", "c.jpg"])   // a.jpg was there before the move
    }

    @Test("Merged move removes the source folder when everything made it")
    func mergedMoveRemovesEmptySource() async throws {
        let s = try Sandbox(); defer { s.cleanup() }
        try s.file("src/album/a.jpg", "AAAA")
        try s.file("src/album/sub/b.jpg", "BBBB")
        try s.file("dest/album/other.jpg", "keep")
        let engine = await s.engine()
        try await engine.enqueue(.move(sources: [s.path("src/album")], destinationDir: s.path("dest")))
        await engine.waitUntilIdle()
        #expect(!s.exists("src/album"))
        #expect(s.names("dest/album") == ["a.jpg", "other.jpg", "sub"])
    }

    @Test("Re-copying to an exFAT disk recognises files that are already there")
    func exFATResume() async throws {
        guard let image = DiskImage(caseSensitive: false, sizeMB: 64, fileSystem: "ExFAT") else { return }
        defer { image.detach() }
        let s = try Sandbox(); defer { s.cleanup() }
        try makeAlbum(s)
        let engine = await s.engine(policy: { _ in Issue.record("should not ask"); return ConflictDecision(.skip) })
        try await engine.enqueue(.copy(sources: [s.path("src/album")], destinationDir: image.mountPoint))
        await engine.waitUntilIdle()
        try FileManager.default.removeItem(at: image.mountPoint.appendingPathComponent("album/b.jpg"))

        let id = try await engine.enqueue(.copy(sources: [s.path("src/album")], destinationDir: image.mountPoint))
        await engine.waitUntilIdle()
        let job = try #require(await engine.job(id))
        #expect(job.notes.contains("Merged “album”: 1 copied, 3 already there"))
    }
}
