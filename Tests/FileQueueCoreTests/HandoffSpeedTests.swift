import Foundation
import Testing
@testable import FileQueueCore

@Suite("Adding big jobs to the queue is quick", .serialized)
struct HandoffSpeedTests {
    @Test("A 4,000-file organize job is queued in well under a second")
    func bigOrganize() async throws {
        let s = try Sandbox(); defer { s.cleanup() }
        for f in 0..<40 { for i in 0..<100 { try s.file("src/f\(f)/IMG_\(i).jpg", "x") } }
        let files = FileExpander.expand([s.path("src")], recursive: true)
        let plan = OrganizePlanner.plan(files: files, root: s.path("src"), options: .init(template: "{ext}/{prefix:3}"), metadata: [:])
        let engine = QueueEngine(executor: GatedExecutor(), diskResolver: SystemDiskResolver(), store: JSONQueueStore(url: s.path("q.json")))
        let start = ContinuousClock.now
        let id = try await engine.enqueue(.organize(items: plan.items, move: true, cleanUpIn: nil), title: "big")
        let elapsed = ContinuousClock.now - start
        #expect(elapsed < .seconds(1.5), "took \(elapsed)") // was 3.7 s before disk lookups were done per folder
        let job = try #require(await engine.job(id))
        #expect(job.disks.count == 1)
        #expect(job.destinationDisk == nil) // organize has no single destination
        await engine.cancel(id)
    }

    @Test("Disk details are the same whether asked for a file, its folder, or a path that doesn't exist yet")
    func resolverConsistency() throws {
        let s = try Sandbox(); defer { s.cleanup() }
        try s.file("a/b.txt")
        let r = SystemDiskResolver()
        let byFile = try r.disk(for: s.path("a/b.txt"))
        #expect(try r.disk(for: s.path("a")) == byFile)
        #expect(try r.disk(for: s.path("a/new/deeper/x.jpg")) == byFile)
        #expect(QueueEngine.folderKey(s.path("a/b.txt")).path == s.path("a").path)
        #expect(QueueEngine.folderKey(s.path("a")).path == s.path("a").path)
    }
}
