import Foundation
import Testing
@testable import FileQueueCore

/// One unreadable item must not sink the whole job unless the user says so.
@Suite("Item errors: skip, stop job, stop all", .serialized)
struct ItemErrorTests {
    /// src/album: a.jpg, b-unreadable/ (folder that can't be listed), c-unreadable.jpg (file that can't be read), d.jpg
    func makeAlbum(_ s: Sandbox) throws {
        try s.file("src/album/a.jpg", "AAAA")
        try s.file("src/album/b-unreadable/inside.jpg", "BBBB")
        try s.file("src/album/c-unreadable.jpg", "CCCC")
        try s.file("src/album/d.jpg", "DDDD")
        lock(s)
    }

    func lock(_ s: Sandbox) {
        chmod(s.path("src/album/b-unreadable").path, 0o000)
        chmod(s.path("src/album/c-unreadable.jpg").path, 0o000)
    }

    func unlock(_ s: Sandbox) {
        chmod(s.path("src/album/b-unreadable").path, 0o755)
        chmod(s.path("src/album/c-unreadable.jpg").path, 0o644)
    }

    func copyAlbum(_ engine: QueueEngine, _ s: Sandbox, onError: ErrorPolicy = .ask) async throws -> UUID {
        try await engine.enqueue(.copy(sources: [s.path("src/album")], destinationDir: try s.dir("dest")),
                                 options: JobOptions(onError: onError), title: "album")
    }

    func engine(_ s: Sandbox, _ handler: @escaping ItemErrorHandler) async -> QueueEngine {
        let engine = await s.engine()
        await engine.setItemErrorHandler(handler)
        return engine
    }

    @Test("Skip & Continue: the rest is copied and the skipped items are listed")
    func skipAndContinue() async throws {
        let s = try Sandbox(); defer { unlock(s); s.cleanup() }
        try makeAlbum(s)
        let asked = Counter()
        let engine = await engine(s) { request in
            asked.increment()
            #expect(!request.message.isEmpty)
            return ItemErrorDecision(.skip)
        }
        let id = try await copyAlbum(engine, s)
        await engine.waitUntilIdle()
        let job = try #require(await engine.job(id))

        #expect(job.state == .completed)
        #expect(asked.value == 2)
        #expect(s.names("dest/album") == ["a.jpg", "d.jpg"])
        #expect(job.problems.count == 2)
        #expect(job.problems.contains { $0.contains("b-unreadable") })
        #expect(job.problems.contains { $0.contains("c-unreadable.jpg") })
        #expect(job.progress.completedBytes == job.progress.totalBytes)
    }

    @Test("Do the same for other errors: asked only once")
    func applyToAll() async throws {
        let s = try Sandbox(); defer { unlock(s); s.cleanup() }
        try makeAlbum(s)
        let asked = Counter()
        let engine = await engine(s) { _ in asked.increment(); return ItemErrorDecision(.skip, applyToAll: true) }
        let id = try await copyAlbum(engine, s)
        await engine.waitUntilIdle()
        #expect(asked.value == 1)
        #expect(try #require(await engine.job(id)).problems.count == 2)
    }

    @Test("Policy 'Skip it and continue' never asks")
    func skipPolicy() async throws {
        let s = try Sandbox(); defer { unlock(s); s.cleanup() }
        try makeAlbum(s)
        let engine = await engine(s) { _ in Issue.record("should not ask"); return ItemErrorDecision(.stopJob) }
        let id = try await copyAlbum(engine, s, onError: .skip)
        await engine.waitUntilIdle()
        #expect(try #require(await engine.job(id)).state == .completed)
        #expect(s.names("dest/album") == ["a.jpg", "d.jpg"])
    }

    @Test("Stop This Job: ends the job; what was done stays and the queue goes on")
    func stopJob() async throws {
        let s = try Sandbox(); defer { unlock(s); s.cleanup() }
        try makeAlbum(s)
        try s.file("other/x.txt", "X")
        let engine = await engine(s) { _ in ItemErrorDecision(.stopJob) }
        let id = try await copyAlbum(engine, s)
        let next = try await engine.enqueue(.copy(sources: [s.path("other/x.txt")], destinationDir: s.path("dest")))
        await engine.waitUntilIdle()

        guard case .failed = try #require(await engine.job(id)).state else { Issue.record("should fail"); return }
        #expect(s.names("dest/album") == ["a.jpg"])           // copied before the error; d.jpg never reached
        #expect(try #require(await engine.job(next)).state == .completed) // the queue carried on
    }

    @Test("Stop All: ends the job and puts the rest of the queue on hold")
    func stopAll() async throws {
        let s = try Sandbox(); defer { unlock(s); s.cleanup() }
        try makeAlbum(s)
        try s.file("other/x.txt", "X")
        let engine = await engine(s) { _ in ItemErrorDecision(.stopAll) }
        let id = try await copyAlbum(engine, s)
        let next = try await engine.enqueue(.copy(sources: [s.path("other/x.txt")], destinationDir: s.path("dest")))
        await engine.waitUntilIdle()

        guard case let .failed(message) = try #require(await engine.job(id)).state else { Issue.record("should fail"); return }
        #expect(message.contains("on hold"))
        #expect(try #require(await engine.job(next)).state == .onHold)
        #expect(!s.exists("dest/x.txt"))
    }

    @Test("Retry after fixing the problem fetches only what was missing")
    func retryFetchesMissing() async throws {
        let s = try Sandbox(); defer { unlock(s); s.cleanup() }
        try makeAlbum(s)
        let engine = await engine(s) { _ in ItemErrorDecision(.skip) }
        let id = try await copyAlbum(engine, s)
        await engine.waitUntilIdle()
        let aInode = FS.stamp(s.path("dest/album/a.jpg"))?.inode

        unlock(s) // e.g. the disk was repaired
        await engine.retry(id)
        await engine.waitUntilIdle()
        let job = try #require(await engine.job(id))
        #expect(job.state == .completed)
        #expect(job.problems.isEmpty)
        #expect(s.names("dest/album") == ["a.jpg", "b-unreadable", "c-unreadable.jpg", "d.jpg"])
        #expect(FS.stamp(s.path("dest/album/a.jpg"))?.inode == aInode) // not copied again
    }

    @Test("An unreadable folder inside a merge is skipped, the rest is merged")
    func errorDuringMerge() async throws {
        let s = try Sandbox(); defer { unlock(s); s.cleanup() }
        try makeAlbum(s)
        try s.file("dest/album/a.jpg", "older")
        let engine = await engine(s) { _ in ItemErrorDecision(.skip) }
        await engine.setConflictHandler { _ in ConflictDecision(.skip) }
        let id = try await copyAlbum(engine, s)
        await engine.waitUntilIdle()
        let job = try #require(await engine.job(id))
        #expect(job.state == .completed)
        #expect(s.names("dest/album") == ["a.jpg", "d.jpg"])
        #expect(job.problems.count == 2)
    }

    @Test("Errors for Trash jobs can be skipped too")
    func trashSkips() async throws {
        let s = try Sandbox(); defer { s.cleanup() }
        try s.file("a.txt")
        try s.file("b.txt")
        let failing = FailingTrash(failFor: "a.txt", folder: s.trash)
        let resolver = SystemDiskResolver()
        let engine = QueueEngine(executor: FileOperationExecutor(diskResolver: resolver, trasher: failing), diskResolver: resolver)
        await engine.setItemErrorHandler { _ in ItemErrorDecision(.skip) }
        let id = try await engine.enqueue(.trash(sources: [s.path("a.txt"), s.path("b.txt")]))
        await engine.waitUntilIdle()
        let job = try #require(await engine.job(id))
        #expect(job.state == .completed)
        #expect(s.exists("a.txt") && !s.exists("b.txt"))
        #expect(job.problems.count == 1)
    }

    @Test("Messages include the system's reason, and disk errors are recognised")
    func messages() {
        let underlying = NSError(domain: NSPOSIXErrorDomain, code: Int(EIO))
        let error = NSError(domain: NSCocoaErrorDomain, code: NSFileReadUnknownError,
                            userInfo: [NSLocalizedDescriptionKey: "The file “100D5100” couldn’t be opened.",
                                       NSUnderlyingErrorKey: underlying])
        #expect(FS.describe(error) == "The file “100D5100” couldn’t be opened. (Input/output error)")
        #expect(FS.isDiskError(error))
        #expect(!FS.isDiskError(NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES))))
    }

    @Test("Jobs saved before the error setting existed still load")
    func oldOptionsJSON() throws {
        let json = #"{"conflictPolicy":"ask","runInParallelAnyway":false,"verifyChecksums":false}"#
        let options = try JSONDecoder().decode(JobOptions.self, from: Data(json.utf8))
        #expect(options.onError == .ask)
        #expect(options.conflictPolicy == .ask)
    }
}

/// A Trash that fails for one particular file name.
struct FailingTrash: Trashing {
    let failFor: String
    let folder: URL
    func trash(_ url: URL) throws -> URL {
        if url.lastPathComponent == failFor { throw NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM)) }
        return try FolderTrash(folder: folder).trash(url)
    }
}
