import Foundation
import Testing
@testable import FileQueueCore

@Suite("Jobs that overlap a queued job", .serialized)
struct OverlapTests {
    func organize(_ files: [String], to folder: String) -> FileOperation {
        .organize(items: files.map { OrganizeItem(source: url($0), destination: url("\(folder)/\(($0 as NSString).lastPathComponent)"), status: .ok) },
                  move: true, cleanUpIn: nil)
    }

    func engine() -> (QueueEngine, GatedExecutor) {
        let executor = GatedExecutor()
        return (QueueEngine(executor: executor, diskResolver: FakeDiskResolver()), executor)
    }

    @Test("The real case: organizing 'jpg' (incl. Group 1), then 'jpg/Group 1' separately")
    func organizeThenSubfolder() async throws {
        let (engine, executor) = engine()
        let all = (0..<10).map { "/HD/jpg/Group 1/f\($0).jpg" } + (0..<10).map { "/HD/jpg/Group 2/g\($0).jpg" }
        try await engine.enqueue(organize(all, to: "/HD/jpg/Unsorted"), title: "Organize jpg")
        do {
            try await engine.enqueue(organize(Array(all.prefix(10)), to: "/HD/jpg/Group 1/Unsorted"))
            Issue.record("should be refused")
        } catch let error as FQError {
            #expect(error.localizedDescription.contains("10 of these files are already in “Organize jpg”"))
        }
        #expect(await engine.jobs.count == 1)
        // "Add Anyway" still works.
        try await engine.enqueue(organize(Array(all.prefix(10)), to: "/HD/jpg/Group 1/Unsorted"), allowOverlap: true)
        #expect(await engine.jobs.count == 2)
        executor.release("Organize jpg")
        await engine.cancel(await engine.jobs[1].id)
    }

    @Test("Folders: copying a folder that a queued job will move files out of; moving a folder a queued job reads")
    func folders() async throws {
        let s = try Sandbox(); defer { s.cleanup() }
        try s.file("photos/a.jpg"); try s.file("photos/b.jpg"); try s.dir("dest")
        let executor = GatedExecutor()
        let engine = QueueEngine(executor: executor, diskResolver: SystemDiskResolver())
        try await engine.enqueue(.move(sources: [s.path("photos/a.jpg")], destinationDir: s.path("dest")), title: "Move a")
        // Copying the folder: one of its files is about to be moved away.
        await #expect(throws: FQError.self) { try await engine.enqueue(.copy(sources: [s.path("photos")], destinationDir: s.path("dest"))) }
        // Trashing the folder clashes too (it contains a file the queued move will take).
        await #expect(throws: FQError.self) { try await engine.enqueue(.trash(sources: [s.path("photos")])) }
        // Moving a file away that a queued copy still needs to read: "still needed by".
        try await engine.enqueue(.copy(sources: [s.path("photos/b.jpg")], destinationDir: s.path("dest")), title: "Copy b")
        do {
            try await engine.enqueue(.move(sources: [s.path("photos/b.jpg")], destinationDir: s.path("dest")))
            Issue.record("should be refused")
        } catch let error as FQError {
            #expect(error.localizedDescription.contains("still needed by “Copy b”"))
        }
        // Copying the same file again is fine (copies don't take it away).
        try await engine.enqueue(.copy(sources: [s.path("photos/b.jpg")], destinationDir: s.path("dest")))
        executor.release("Move a")
        for job in await engine.jobs { await engine.cancel(job.id) }
    }

    @Test("Finished jobs don't count; copies reading the same files don't conflict")
    func finishedAndCopies() async throws {
        let (engine, executor) = engine()
        let a = try await engine.enqueue(organize(["/HD/x/1.jpg"], to: "/HD/y"), title: "first")
        executor.release("first")
        #expect(await eventually(engine) { $0.first { $0.id == a }?.state == .completed })
        try await engine.enqueue(organize(["/HD/x/1.jpg"], to: "/HD/z"), title: "second") // first is done: fine
        try await engine.enqueue(.copy(sources: [url("/HD/q/1.jpg")], destinationDir: url("/HD/r")), title: "copy 1")
        try await engine.enqueue(.copy(sources: [url("/HD/q/1.jpg")], destinationDir: url("/HD/s")), title: "copy 2")
        for job in await engine.jobs { await engine.cancel(job.id) }
    }

    @Test("Checking a small job against a huge queued one is quick")
    func speed() async throws {
        let (engine, executor) = engine()
        let big = (0..<70_000).map { "/HD/jpg/Group \($0 / 1000)/f\($0).jpg" }
        try await engine.enqueue(organize(big, to: "/HD/jpg/Unsorted"), title: "big")
        let start = ContinuousClock.now
        await #expect(throws: FQError.self) { try await engine.enqueue(organize(Array(big.prefix(500)), to: "/HD/elsewhere")) }
        #expect(ContinuousClock.now - start < .seconds(1))
        executor.release("big")
        for job in await engine.jobs { await engine.cancel(job.id) }
    }
}
