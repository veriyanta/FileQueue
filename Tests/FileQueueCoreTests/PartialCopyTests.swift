import Foundation
import Testing
@testable import FileQueueCore

/// Unfinished copies must never sit at the destination under the real name.
@Suite("Unfinished copies", .serialized)
struct PartialCopyTests {
    func context(jobID: UUID, control: JobControl = JobControl()) -> ExecutionContext {
        ExecutionContext(jobID: jobID, jobTitle: "t", control: control, progress: ProgressReporter { _ in },
                         journal: JournalRecorder(), resolveConflict: { _ in ConflictDecision(.skip) })
    }

    func names(_ dir: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).sorted()
    }

    @Test("A finished copy leaves no temporary item behind")
    func noLeftovers() async throws {
        let s = try Sandbox(); defer { s.cleanup() }
        try s.file("src/folder/a.txt", "A")
        try s.file("src/b.txt", "B")
        let dest = try s.dir("dest")
        let engine = await s.engine()
        try await engine.enqueue(.copy(sources: [s.path("src/folder"), s.path("src/b.txt")], destinationDir: dest))
        await engine.waitUntilIdle()
        #expect(names(dest) == ["b.txt", "folder"])
    }

    @Test("A restarted job replaces its own half-finished copy instead of hitting a conflict")
    func restartCleansUp() async throws {
        let s = try Sandbox(); defer { s.cleanup() }
        try s.file("src/clip.mov", String(repeating: "x", count: 10_000))
        let dest = try s.dir("dest")
        let jobID = UUID()
        // What an interrupted run leaves behind: a partial copy under the job's hidden name.
        let leftover = FS.partialURL(for: dest.appendingPathComponent("clip.mov"), jobID: jobID)
        try Data("half".utf8).write(to: leftover)

        let job = Job(id: jobID, title: "t", operation: .copy(sources: [s.path("src/clip.mov")], destinationDir: dest),
                      options: JobOptions(conflictPolicy: .ask), disks: [])
        let asked = Counter()
        let ctx = ExecutionContext(jobID: jobID, jobTitle: "t", control: JobControl(), progress: ProgressReporter { _ in },
                                   journal: JournalRecorder(), resolveConflict: { _ in asked.increment(); return ConflictDecision(.skip) })
        try await FileOperationExecutor(trasher: FolderTrash(folder: s.trash)).execute(job: job, context: ctx)

        #expect(asked.value == 0) // no conflict: the leftover is hidden and ours
        #expect(names(dest) == ["clip.mov"])
        #expect(FS.totalSize(dest.appendingPathComponent("clip.mov")).bytes == 10_000)
    }

    @Test("Temporary names are hidden, per job, and stay within the length limit")
    func partialNames() {
        let id = UUID(uuidString: "ABCDEF12-0000-0000-0000-000000000000")!
        let url = FS.partialURL(for: URL(fileURLWithPath: "/d/Desktop"), jobID: id)
        #expect(url.lastPathComponent == ".Desktop.abcdef12.fqpart")
        let long = FS.partialURL(for: URL(fileURLWithPath: "/d/" + String(repeating: "é", count: 127)), jobID: id)
        #expect(long.lastPathComponent.utf8.count <= 255)
        #expect(long.lastPathComponent.hasSuffix(".abcdef12.fqpart"))
    }

    @Test("Cancelling a cross-disk copy leaves neither the item nor a temporary copy")
    func cancelLeavesNothing() async throws {
        guard let image = DiskImage(caseSensitive: false, sizeMB: 200) else { return }
        defer { image.detach() }
        let s = try Sandbox(); defer { s.cleanup() }
        let big = s.path("huge.bin")
        FileManager.default.createFile(atPath: big.path, contents: nil)
        let handle = try FileHandle(forWritingTo: big)
        for _ in 0..<120 { handle.write(Data(repeating: 7, count: 1 << 20)) }
        try handle.close()

        let engine = await s.engine()
        let id = try await engine.enqueue(.copy(sources: [big], destinationDir: image.mountPoint))
        _ = await eventually(engine, timeout: .seconds(10)) { jobs in
            jobs.first { $0.id == id }.map { $0.progress.completedBytes > 0 || $0.state.isFinished } ?? false
        }
        await engine.cancel(id)
        await engine.waitUntilIdle()
        let finished = await engine.job(id)?.state
        if finished == .completed { return } // the copy won the race; nothing to check
        #expect(finished == .cancelled)
        #expect(!names(image.mountPoint).contains { $0.hasPrefix(".huge.bin") || $0 == "huge.bin" })
    }

    @Test("Copy, move, rename and batch rename work on an exFAT disk")
    func exFAT() async throws {
        guard let image = DiskImage(caseSensitive: false, sizeMB: 64, fileSystem: "ExFAT") else { return }
        defer { image.detach() }
        let s = try Sandbox(); defer { s.cleanup() }
        try s.file("a.txt", "A")
        try s.file("b.txt", "B")
        let engine = await s.engine()
        let root = image.mountPoint

        try await engine.enqueue(.copy(sources: [s.path("a.txt")], destinationDir: root))
        try await engine.enqueue(.move(sources: [s.path("b.txt")], destinationDir: root))
        await engine.waitUntilIdle()
        #expect(FS.itemExists(root.appendingPathComponent("a.txt")))
        #expect(FS.itemExists(root.appendingPathComponent("b.txt")))
        #expect(!s.exists("b.txt"))

        // Same-disk operations on exFAT use the rename fallback.
        try FileManager.default.createDirectory(at: root.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try await engine.enqueue(.move(sources: [root.appendingPathComponent("a.txt")], destinationDir: root.appendingPathComponent("sub")))
        try await engine.enqueue(.rename(source: root.appendingPathComponent("b.txt"), newName: "c.txt"))
        await engine.waitUntilIdle()
        #expect(FS.itemExists(root.appendingPathComponent("sub/a.txt")))
        #expect(FS.itemExists(root.appendingPathComponent("c.txt")))

        // The fallback must still refuse to overwrite.
        try Data("keep".utf8).write(to: root.appendingPathComponent("keep.txt"))
        #expect(throws: FQError.self) {
            try FS.renameExclusive(root.appendingPathComponent("c.txt"), root.appendingPathComponent("keep.txt"))
        }
        #expect(try String(contentsOf: root.appendingPathComponent("keep.txt"), encoding: .utf8) == "keep")
        #expect(await engine.jobs.allSatisfy { $0.state == .completed })
    }
}

@Suite("Leftovers from interrupted runs")
struct LeftoverCleanupTests {
    @Test("Resuming a job removes its own hidden leftovers (including folders and exFAT companions), and nobody else's")
    func cleansOwnLeftovers() async throws {
        let s = try Sandbox(); defer { s.cleanup() }
        try s.file("src/OPIE/a.xlsx", "A")
        try s.file("src/OPIE/Keg Makmin/b.xlsx", "B")
        try s.file("dest/OPIE/a.xlsx", "A")
        let jobID = UUID()
        let dest = s.path("dest/OPIE")
        let mine = FS.partialURL(for: dest.appendingPathComponent("Keg Makmin"), jobID: jobID)
        try FileManager.default.createDirectory(at: mine, withIntermediateDirectories: true)
        try Data("half".utf8).write(to: mine.appendingPathComponent("b.xlsx"))
        try Data().write(to: dest.appendingPathComponent("._" + mine.lastPathComponent))
        let othersLeftover = FS.partialURL(for: dest.appendingPathComponent("x"), jobID: UUID())
        try Data("other job".utf8).write(to: othersLeftover)
        // Make dest/OPIE/a.xlsx identical to the source so the merge has nothing to ask.
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_500_000_000)], ofItemAtPath: s.path("src/OPIE/a.xlsx").path)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_500_000_000)], ofItemAtPath: s.path("dest/OPIE/a.xlsx").path)

        let job = Job(id: jobID, title: "t", operation: .copy(sources: [s.path("src/OPIE")], destinationDir: s.path("dest")),
                      options: JobOptions(), disks: [])
        let ctx = ExecutionContext(jobID: jobID, jobTitle: "t", control: JobControl(), progress: ProgressReporter { _ in },
                                   journal: JournalRecorder(), resolveConflict: { _ in Issue.record("no conflicts expected"); return ConflictDecision(.skip) })
        try await FileOperationExecutor(trasher: FolderTrash(folder: s.trash)).execute(job: job, context: ctx)

        let names = try FileManager.default.contentsOfDirectory(atPath: dest.path).sorted()
        #expect(names == [othersLeftover.lastPathComponent, "Keg Makmin", "a.xlsx"]) // only another job's leftover remains
        #expect(s.read("dest/OPIE/Keg Makmin/b.xlsx") == "B")
    }
}
