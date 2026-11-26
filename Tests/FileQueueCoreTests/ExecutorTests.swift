import Foundation
import Testing
@testable import FileQueueCore

@Suite("File operations, conflicts and undo", .serialized)
struct ExecutorTests {
    // MARK: Copy

    @Test("Copies files, folders and symlinks (links stay links)")
    func copyTree() async throws {
        let s = try Sandbox(); defer { s.cleanup() }
        try s.file("src/a.txt", "A")
        try s.file("src/folder/b.txt", "B")
        try FileManager.default.createSymbolicLink(atPath: s.path("src/link").path, withDestinationPath: "a.txt")
        try s.dir("dest")
        let engine = await s.engine()
        let id = try await engine.enqueue(.copy(
            sources: [s.path("src/a.txt"), s.path("src/folder"), s.path("src/link")], destinationDir: s.path("dest")))
        await engine.waitUntilIdle()

        let job = try #require(await engine.job(id))
        #expect(job.state == .completed)
        #expect(s.read("dest/a.txt") == "A")
        #expect(s.read("dest/folder/b.txt") == "B")
        let link = try FileManager.default.destinationOfSymbolicLink(atPath: s.path("dest/link").path)
        #expect(link == "a.txt")
        #expect(s.read("src/a.txt") == "A") // source untouched
        #expect(job.progress.completedBytes == job.progress.totalBytes)
        #expect(job.journal.count == 3)
    }

    @Test("Copying into the same folder makes a numbered duplicate")
    func duplicateInPlace() async throws {
        let s = try Sandbox(); defer { s.cleanup() }
        try s.file("Report.pdf")
        let engine = await s.engine()
        try await engine.enqueue(.copy(sources: [s.path("Report.pdf")], destinationDir: s.root))
        await engine.waitUntilIdle()
        #expect(s.names() == ["Report 2.pdf", "Report.pdf"])
    }

    @Test("A folder can't be copied into itself")
    func intoItself() async throws {
        let s = try Sandbox(); defer { s.cleanup() }
        try s.dir("a/b")
        let engine = await s.engine()
        let id = try await engine.enqueue(.copy(sources: [s.path("a")], destinationDir: s.path("a/b")))
        await engine.waitUntilIdle()
        guard case .failed = try #require(await engine.job(id)).state else { Issue.record("should fail"); return }
    }

    @Test("Conflict policies: skip, keep both, replace (old one goes to Trash)")
    func conflictPolicies() async throws {
        let s = try Sandbox(); defer { s.cleanup() }
        try s.file("src/x.txt", "new")
        try s.file("dest/x.txt", "old")
        let engine = await s.engine()

        try await engine.enqueue(.copy(sources: [s.path("src/x.txt")], destinationDir: s.path("dest")), options: JobOptions(conflictPolicy: .skip))
        await engine.waitUntilIdle()
        #expect(s.read("dest/x.txt") == "old")

        try await engine.enqueue(.copy(sources: [s.path("src/x.txt")], destinationDir: s.path("dest")), options: JobOptions(conflictPolicy: .keepBoth))
        await engine.waitUntilIdle()
        #expect(s.read("dest/x 2.txt") == "new")

        try await engine.enqueue(.copy(sources: [s.path("src/x.txt")], destinationDir: s.path("dest")), options: JobOptions(conflictPolicy: .replace))
        await engine.waitUntilIdle()
        #expect(s.read("dest/x.txt") == "new")
        #expect(s.read("_Trash/x.txt") == "old")
    }

    @Test("Ask: the handler decides, and 'apply to all' covers the rest of the job")
    func askWithApplyToAll() async throws {
        let s = try Sandbox(); defer { s.cleanup() }
        for n in 1...3 { try s.file("src/\(n).txt", "new"); try s.file("dest/\(n).txt", "old") }
        let asked = Counter()
        let engine = await s.engine(policy: { _ in
            asked.increment()
            return ConflictDecision(.keepBoth, applyToAll: true)
        })
        try await engine.enqueue(.copy(sources: (1...3).map { s.path("src/\($0).txt") }, destinationDir: s.path("dest")))
        await engine.waitUntilIdle()
        #expect(asked.value == 1)
        #expect(s.names("dest") == ["1 2.txt", "1.txt", "2 2.txt", "2.txt", "3 2.txt", "3.txt"])
    }

    @Test("Cancelling before the copy starts leaves nothing behind")
    func cancelLeavesNothing() async throws {
        let s = try Sandbox(); defer { s.cleanup() }
        try s.file("src/a.txt")
        try s.dir("dest")
        let control = JobControl()
        control.cancel()
        let context = ExecutionContext(
            jobID: UUID(), jobTitle: "t", control: control, progress: ProgressReporter { _ in },
            journal: JournalRecorder(), resolveConflict: { _ in ConflictDecision(.skip) })
        let job = Job(title: "t", operation: .copy(sources: [s.path("src/a.txt")], destinationDir: s.path("dest")), options: JobOptions(), disks: [])
        await #expect(throws: CancellationError.self) {
            try await FileOperationExecutor(trasher: FolderTrash(folder: s.trash)).execute(job: job, context: context)
        }
        #expect(s.names("dest").isEmpty)
    }

    // MARK: Move

    @Test("Move on the same disk")
    func moveSameDisk() async throws {
        let s = try Sandbox(); defer { s.cleanup() }
        try s.file("a/one.txt", "1")
        try s.dir("b")
        let engine = await s.engine()
        try await engine.enqueue(.move(sources: [s.path("a/one.txt")], destinationDir: s.path("b")))
        await engine.waitUntilIdle()
        #expect(!s.exists("a/one.txt"))
        #expect(s.read("b/one.txt") == "1")
    }

    // MARK: Rename

    @Test("Case-only rename works on a case-insensitive disk")
    func caseOnlyRename() async throws {
        let s = try Sandbox(); defer { s.cleanup() }
        try s.file("photo.jpg")
        let engine = await s.engine()
        try await engine.enqueue(.rename(source: s.path("photo.jpg"), newName: "Photo.JPG"))
        await engine.waitUntilIdle()
        #expect(s.names() == ["Photo.JPG"])
    }

    @Test("Rename onto an existing name follows the conflict policy")
    func renameConflict() async throws {
        let s = try Sandbox(); defer { s.cleanup() }
        try s.file("a.txt", "A")
        try s.file("b.txt", "B")
        let engine = await s.engine()
        try await engine.enqueue(.rename(source: s.path("a.txt"), newName: "b.txt"), options: JobOptions(conflictPolicy: .keepBoth))
        await engine.waitUntilIdle()
        #expect(s.read("b.txt") == "B")
        #expect(s.read("b 2.txt") == "A")
    }

    @Test("Invalid names are rejected", arguments: ["", "a/b", "a:b", ".", String(repeating: "x", count: 256)])
    func invalidNames(name: String) async throws {
        let s = try Sandbox(); defer { s.cleanup() }
        try s.file("a.txt")
        let engine = await s.engine()
        let id = try await engine.enqueue(.rename(source: s.path("a.txt"), newName: name))
        await engine.waitUntilIdle()
        guard case .failed = try #require(await engine.job(id)).state else { Issue.record("should fail"); return }
        #expect(s.names() == ["a.txt"])
    }

    // MARK: Batch rename

    @Test("Batch rename handles swaps (A↔B) via temporary names")
    func batchSwap() async throws {
        let s = try Sandbox(); defer { s.cleanup() }
        try s.file("A.txt", "was A")
        try s.file("B.txt", "was B")
        let plan = [
            RenamePlanItem(original: s.path("A.txt"), proposedName: "B.txt", status: .ok),
            RenamePlanItem(original: s.path("B.txt"), proposedName: "A.txt", status: .ok),
        ]
        let engine = await s.engine()
        let id = try await engine.enqueue(.batchRename(items: plan))
        await engine.waitUntilIdle()
        #expect(try #require(await engine.job(id)).state == .completed)
        #expect(s.read("A.txt") == "was B")
        #expect(s.read("B.txt") == "was A")
        #expect(s.names() == ["A.txt", "B.txt"])
    }

    @Test("Batch rename is all-or-nothing: a failure rolls every name back")
    func batchRollback() async throws {
        let s = try Sandbox(); defer { s.cleanup() }
        try s.file("1.txt"); try s.file("2.txt"); try s.file("taken.txt")
        // Planned while "taken.txt" was free; it appeared before the job ran.
        let plan = [
            RenamePlanItem(original: s.path("1.txt"), proposedName: "one.txt", status: .ok),
            RenamePlanItem(original: s.path("2.txt"), proposedName: "taken.txt", status: .ok),
        ]
        let engine = await s.engine()
        let id = try await engine.enqueue(.batchRename(items: plan))
        await engine.waitUntilIdle()
        guard case .failed = try #require(await engine.job(id)).state else { Issue.record("should fail"); return }
        #expect(s.names() == ["1.txt", "2.txt", "taken.txt"])
    }

    @Test("A plan with errors is refused")
    func batchRefusesErrors() async throws {
        let s = try Sandbox(); defer { s.cleanup() }
        try s.file("1.txt")
        let plan = [RenamePlanItem(original: s.path("1.txt"), proposedName: "a/b", status: .invalid("bad"))]
        let engine = await s.engine()
        let id = try await engine.enqueue(.batchRename(items: plan))
        await engine.waitUntilIdle()
        #expect(try #require(await engine.job(id)).state == .failed(FQError.planHasErrors.localizedDescription))
    }

    // MARK: Trash & undo

    @Test("Undo: trash comes back, copies go to Trash, moves and renames go back")
    func undoEverything() async throws {
        let s = try Sandbox(); defer { s.cleanup() }
        try s.file("keep.txt", "K")
        try s.file("move.txt", "M")
        try s.file("old.txt", "R")
        try s.dir("dest")
        let engine = await s.engine()

        let trash = try await engine.enqueue(.trash(sources: [s.path("keep.txt")]))
        let copy = try await engine.enqueue(.copy(sources: [s.path("move.txt")], destinationDir: s.path("dest")))
        await engine.waitUntilIdle()
        let move = try await engine.enqueue(.move(sources: [s.path("move.txt")], destinationDir: s.root.appendingPathComponent("dest")), options: JobOptions(conflictPolicy: .keepBoth))
        let rename = try await engine.enqueue(.rename(source: s.path("old.txt"), newName: "new.txt"))
        await engine.waitUntilIdle()
        #expect(s.names() == ["dest", "new.txt"])
        #expect(s.names("dest") == ["move 2.txt", "move.txt"])

        for id in [rename, move, copy, trash] { try await engine.undo(id) }
        await engine.waitUntilIdle()
        #expect(s.names() == ["dest", "keep.txt", "move.txt", "old.txt"])
        #expect(s.names("dest").isEmpty)
        #expect(await engine.jobs.allSatisfy { $0.state == .completed })
    }

    @Test("Undo skips a file that was changed after the operation")
    func undoSkipsModified() async throws {
        let s = try Sandbox(); defer { s.cleanup() }
        try s.file("a.txt", "A")
        try s.dir("dest")
        let engine = await s.engine()
        let id = try await engine.enqueue(.copy(sources: [s.path("a.txt")], destinationDir: s.path("dest")))
        await engine.waitUntilIdle()

        try await Task.sleep(for: .milliseconds(20))
        try Data("edited".utf8).write(to: s.path("dest/a.txt"))
        let undoID = try #require(try await engine.undo(id))
        await engine.waitUntilIdle()

        #expect(s.read("dest/a.txt") == "edited")
        let undoJob = try #require(await engine.job(undoID))
        #expect(undoJob.notes.contains { $0.contains("changed") })
    }

    @Test("A job can only be undone once")
    func undoOnce() async throws {
        let s = try Sandbox(); defer { s.cleanup() }
        try s.file("a.txt")
        let engine = await s.engine()
        let id = try await engine.enqueue(.rename(source: s.path("a.txt"), newName: "b.txt"))
        await engine.waitUntilIdle()
        #expect(try await engine.undo(id) != nil)
        #expect(try await engine.undo(id) == nil)
    }
}

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    var value: Int { lock.withLock { n } }
    func increment() { lock.withLock { n += 1 } }
}

// MARK: - Disk images

@Suite("Real disks (attached disk images)", .serialized)
struct DiskImageTests {
    @Test("Each disk image is its own lane, separate from the internal disk")
    func separateDisks() throws {
        guard let image = DiskImage(caseSensitive: false) else { return skipNote() }
        defer { image.detach() }
        let s = try Sandbox(); defer { s.cleanup() }
        let resolver = SystemDiskResolver()
        let builtIn = try resolver.disk(for: s.root)
        let external = try resolver.disk(for: image.mountPoint)
        #expect(builtIn.id != external.id)
        #expect(external.volumePath == image.mountPoint.path)
        // A not-yet-existing path resolves to its nearest parent's disk.
        #expect(try resolver.disk(for: image.mountPoint.appendingPathComponent("new/deep")).id == external.id)
    }

    @Test("Cross-disk move copies, verifies (checksums), then removes the source")
    func crossDiskMove() async throws {
        guard let image = DiskImage(caseSensitive: false) else { return skipNote() }
        defer { image.detach() }
        let s = try Sandbox(); defer { s.cleanup() }
        try s.file("big/data.bin", String(repeating: "x", count: 3_000_000))
        try s.file("big/nested/small.txt", "small")
        let engine = await s.engine()
        let id = try await engine.enqueue(
            .move(sources: [s.path("big")], destinationDir: image.mountPoint),
            options: JobOptions(verifyChecksums: true))
        await engine.waitUntilIdle()
        let job = try #require(await engine.job(id))
        #expect(job.state == .completed)
        #expect(job.disks.count == 2)
        #expect(!s.exists("big"))
        #expect(FS.totalSize(image.mountPoint.appendingPathComponent("big")).bytes == 3_000_005)

        // And undo brings it back across disks.
        try await engine.undo(id)
        await engine.waitUntilIdle()
        #expect(s.read("big/nested/small.txt") == "small")
    }

    @Test("Cancelling a cross-disk copy mid-file removes the partial copy")
    func cancelMidCopy() async throws {
        guard let image = DiskImage(caseSensitive: false, sizeMB: 200) else { return skipNote() }
        defer { image.detach() }
        let s = try Sandbox(); defer { s.cleanup() }
        let big = s.path("huge.bin")
        FileManager.default.createFile(atPath: big.path, contents: nil)
        let handle = try FileHandle(forWritingTo: big)
        let chunk = Data(repeating: 7, count: 1 << 20)
        for _ in 0..<120 { handle.write(chunk) }
        try handle.close()

        let engine = await s.engine()
        let id = try await engine.enqueue(.copy(sources: [big], destinationDir: image.mountPoint))
        _ = await eventually(engine, timeout: .seconds(10)) { jobs in
            jobs.first { $0.id == id }.map { $0.progress.completedBytes > 0 || $0.state.isFinished } ?? false
        }
        await engine.cancel(id)
        await engine.waitUntilIdle()
        let job = try #require(await engine.job(id))
        if job.state == .completed { return } // copy finished before cancel landed; nothing to check
        #expect(job.state == .cancelled)
        #expect(!FS.itemExists(image.mountPoint.appendingPathComponent("huge.bin")))
    }

    @Test("On a case-sensitive disk, a.txt and A.txt are different names")
    func caseSensitivePlan() throws {
        guard let image = DiskImage(caseSensitive: true) else { return skipNote() }
        defer { image.detach() }
        let a = image.mountPoint.appendingPathComponent("a.txt")
        let b = image.mountPoint.appendingPathComponent("b.txt")
        try Data().write(to: a)
        try Data().write(to: b)
        // Renaming b.txt → A.txt is fine here (it would collide on a case-insensitive disk).
        let plan = RenameEngine.makePlan(files: [b], rules: [.replace("b", with: "A")])
        #expect(plan[0].status == .ok)
        #expect(try SystemDiskResolver().disk(for: a).isCaseSensitive)
    }

    func skipNote() {
        print("⚠️ hdiutil unavailable here; skipping disk-image test")
    }
}
