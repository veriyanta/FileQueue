import Foundation
import Testing
@testable import FileQueueCore

@Suite("QueueEngine (live scheduling)")
struct QueueEngineTests {
    let executor = GatedExecutor()

    func makeEngine(max: Int = 4, store: (any QueueStore)? = nil) -> QueueEngine {
        QueueEngine(executor: executor, diskResolver: FakeDiskResolver(), store: store, maxConcurrent: max)
    }

    func copy(_ from: String, _ to: String) -> FileOperation {
        .copy(sources: [url("/\(from)/file")], destinationDir: url("/\(to)/dest"))
    }

    @Test("J1–J5: same disk queues, different disks run in parallel")
    func specExampleLive() async throws {
        let engine = makeEngine()
        try await engine.enqueue(copy("HD", "HD"), title: "J1")
        try await engine.enqueue(copy("HD", "HD"), title: "J2")
        try await engine.enqueue(copy("USB-A", "USB-A"), title: "J3")
        try await engine.enqueue(copy("USB-B", "NAS"), title: "J4")
        try await engine.enqueue(copy("USB-A", "NAS"), title: "J5")

        #expect(await eventually(engine) { $0.state("J1") == .running && $0.state("J3") == .running && $0.state("J4") == .running })
        var jobs = await engine.jobs
        #expect(jobs.state("J2") == .waiting(on: [DiskID("HD")]))
        #expect(jobs.state("J5") == .waiting(on: [DiskID("USB-A"), DiskID("NAS")]))

        executor.release("J3") // USB-A frees up, but NAS is still busy with J4
        #expect(await eventually(engine) { $0.state("J3") == .completed })
        jobs = await engine.jobs
        #expect(jobs.state("J5") == .waiting(on: [DiskID("NAS")]))

        executor.release("J4")
        #expect(await eventually(engine) { $0.state("J5") == .running })

        executor.release("J1")
        #expect(await eventually(engine) { $0.state("J2") == .running })

        executor.release("J2", "J5")
        await engine.waitUntilIdle()
        #expect(await engine.jobs.allSatisfy { $0.state == .completed })
        // J1, J3 and J4 start together (in any order); then J5, then J2.
        #expect(Set(executor.started.prefix(3)) == ["J1", "J3", "J4"])
        #expect(Array(executor.started.suffix(2)) == ["J5", "J2"])
    }

    @Test("Jobs on the same disk run in FIFO order")
    func fifoOnSameDisk() async throws {
        let engine = makeEngine()
        for n in 1...4 { try await engine.enqueue(copy("HD", "HD"), title: "J\(n)") }
        for n in 1...4 {
            #expect(await eventually(engine) { $0.state("J\(n)") == .running })
            executor.release("J\(n)")
        }
        await engine.waitUntilIdle()
        #expect(executor.started == ["J1", "J2", "J3", "J4"])
    }

    @Test("Reordering changes who goes first on a shared disk")
    func reorder() async throws {
        let engine = makeEngine()
        try await engine.enqueue(copy("HD", "HD"), title: "J1")
        try await engine.enqueue(copy("HD", "HD"), title: "J2")
        let j3 = try await engine.enqueue(copy("HD", "HD"), title: "J3")
        await engine.move(j3, by: -1)
        executor.release("J1", "J2", "J3")
        await engine.waitUntilIdle()
        #expect(executor.started == ["J1", "J3", "J2"])
    }

    @Test("Global limit caps parallel jobs; setting it higher starts more")
    func globalLimit() async throws {
        let engine = makeEngine(max: 1)
        try await engine.enqueue(copy("A", "A"), title: "A")
        try await engine.enqueue(copy("B", "B"), title: "B")
        #expect(await eventually(engine) { $0.state("A") == .running })
        #expect(await engine.jobs.state("B") == .waiting(on: []))
        await engine.setMaxConcurrent(2)
        #expect(await eventually(engine) { $0.state("B") == .running })
        executor.release("A", "B")
        await engine.waitUntilIdle()
    }

    @Test("Run in parallel anyway starts despite a busy disk")
    func override() async throws {
        let engine = makeEngine()
        try await engine.enqueue(copy("HD", "HD"), title: "J1")
        try await engine.enqueue(copy("HD", "HD"), options: JobOptions(runInParallelAnyway: true), title: "J2")
        #expect(await eventually(engine) { $0.state("J1") == .running && $0.state("J2") == .running })
        executor.release("J1", "J2")
        await engine.waitUntilIdle()
    }

    @Test("Pausing keeps the disk; cancelling frees it")
    func pauseAndCancel() async throws {
        let engine = makeEngine()
        let j1 = try await engine.enqueue(copy("HD", "HD"), title: "J1")
        try await engine.enqueue(copy("HD", "HD"), title: "J2")
        #expect(await eventually(engine) { $0.state("J1") == .running })

        await engine.pause(j1)
        try await Task.sleep(for: .milliseconds(50))
        #expect(await engine.jobs.state("J1") == .paused)
        #expect(await engine.jobs.state("J2") == .waiting(on: [DiskID("HD")]))

        await engine.cancel(j1)
        #expect(await eventually(engine) { $0.state("J1") == .cancelled && $0.state("J2") == .running })
        executor.release("J2")
        await engine.waitUntilIdle()
    }

    @Test("Putting a queued job on hold lets the next one go first")
    func holdQueued() async throws {
        let engine = makeEngine()
        try await engine.enqueue(copy("HD", "HD"), title: "J1")
        let j2 = try await engine.enqueue(copy("HD", "HD"), title: "J2")
        try await engine.enqueue(copy("HD", "HD"), title: "J3")
        await engine.pause(j2)
        executor.release("J1", "J3")
        #expect(await eventually(engine) { $0.state("J3") == .completed })
        #expect(await engine.jobs.state("J2") == .onHold)
        await engine.resume(j2)
        executor.release("J2")
        await engine.waitUntilIdle()
        #expect(await engine.jobs.state("J2") == .completed)
    }

    @Test("Ejecting a disk fails the jobs waiting on it")
    func unmount() async throws {
        let engine = makeEngine()
        try await engine.enqueue(copy("USB", "USB"), title: "J1")
        try await engine.enqueue(copy("USB", "HD"), title: "J2")
        #expect(await eventually(engine) { $0.state("J1") == .running })
        await engine.handleUnmount(volumePath: "/USB")
        guard case let .failed(message) = await engine.jobs.state("J2") else {
            Issue.record("J2 should have failed"); return
        }
        #expect(message.contains("USB"))
        executor.release("J1")
        await engine.waitUntilIdle()
    }

    @Test("Enqueue fails if a disk isn't available")
    func unavailableDisk() async {
        let engine = makeEngine()
        await #expect(throws: FQError.self) {
            try await engine.enqueue(copy("Ejected", "HD"))
        }
    }

    @Test("After relaunch, running jobs are interrupted and queued jobs are on hold")
    func persistence() async throws {
        let store = MemoryStore()
        let engine = makeEngine(store: store)
        try await engine.enqueue(copy("HD", "HD"), title: "J1")
        try await engine.enqueue(copy("HD", "HD"), title: "J2")
        #expect(await eventually(engine) { $0.state("J1") == .running })
        // Simulate a crash: a new engine loads what was saved.
        let relaunched = QueueEngine(executor: GatedExecutor(), diskResolver: FakeDiskResolver(), store: store)
        let jobs = await relaunched.jobs
        #expect(jobs.state("J1") == .interrupted)
        #expect(jobs.state("J2") == .onHold)
        executor.release("J1", "J2")
        await engine.waitUntilIdle()
    }
}

@Suite("Queue file")
struct QueueStoreTests {
    @Test("Round-trips jobs, and moves an unreadable file aside instead of losing it")
    func storeSafety() async throws {
        let s = try Sandbox(); defer { s.cleanup() }
        let store = JSONQueueStore(url: s.path("queue.json"))
        let job = Job(title: "t", operation: .trash(sources: [s.path("x")]), options: JobOptions(), disks: [], state: .onHold)
        try store.save([job])
        #expect(try store.load() == [job])

        try Data("not json".utf8).write(to: store.url)
        #expect(throws: (any Error).self) { try store.load() }
        #expect(!FS.itemExists(store.url))
        #expect(s.names().contains { $0.hasPrefix("queue.unreadable-") })
    }
}

@Suite("Destination disk")
struct DestinationDiskTests {
    @Test("Copies and moves record which disk they write to, even if a source is on it too")
    func recorded() async throws {
        let engine = QueueEngine(executor: GatedExecutor(), diskResolver: FakeDiskResolver())
        let id = try await engine.enqueue(.move(sources: [url("/B/x"), url("/A/y")], destinationDir: url("/B/dest")), title: "m")
        let job = try #require(await engine.job(id))
        #expect(job.destinationDisk == DiskID("B"))
        #expect(job.disks.map(\.id) == [DiskID("B"), DiskID("A")]) // dest disk isn't last here
        let rename = try await engine.enqueue(.rename(source: url("/A/z"), newName: "w"), title: "r")
        #expect(await engine.job(rename)?.destinationDisk == nil)
        await engine.cancel(id); await engine.cancel(rename)
    }

    @Test("Jobs saved before this field existed still load")
    func oldJSON() throws {
        let job = Job(title: "t", operation: .trash(sources: []), options: JobOptions(), disks: [])
        var dict = try JSONSerialization.jsonObject(with: JSONEncoder().encode(job)) as! [String: Any]
        dict.removeValue(forKey: "destinationDisk")
        let decoded = try JSONDecoder().decode(Job.self, from: JSONSerialization.data(withJSONObject: dict))
        #expect(decoded.destinationDisk == nil)
    }
}
