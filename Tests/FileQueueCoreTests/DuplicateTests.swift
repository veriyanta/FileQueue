import Foundation
import Testing
@testable import FileQueueCore

@Suite("Merge, keeping both if different", .serialized)
struct MergeKeepBothTests {
    func setDate(_ url: URL, _ date: Date) throws {
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
    }

    func prepare(_ s: Sandbox) throws {
        try s.file("src/album/a.jpg", "AAAA")
        try s.file("src/album/b.jpg", "BBBB")
        try s.file("src/album/c.jpg", "CCCC")
        try s.file("dest/album/a.jpg", "AAAA") // same contents, but copied at another time
        try setDate(s.path("dest/album/a.jpg"), Date(timeIntervalSince1970: 1_000_000))
        try s.file("dest/album/b.jpg", "BBBX") // same name and size, different contents
    }

    @Test("Same contents are left alone, different ones are kept as “name 2”, never asking")
    func copy() async throws {
        let s = try Sandbox(); defer { s.cleanup() }
        try prepare(s)
        let asked = Counter()
        let engine = await s.engine(policy: { _ in asked.increment(); return ConflictDecision(.skip) })
        let id = try await engine.enqueue(.copy(sources: [s.path("src/album")], destinationDir: s.path("dest")),
                                          options: JobOptions(conflictPolicy: .mergeKeepBoth))
        await engine.waitUntilIdle()
        let job = try #require(await engine.job(id))
        #expect(job.state == .completed)
        #expect(asked.value == 0)
        #expect(s.names("dest/album") == ["a.jpg", "b 2.jpg", "b.jpg", "c.jpg"])
        #expect(s.read("dest/album/b.jpg") == "BBBX")
        #expect(s.read("dest/album/b 2.jpg") == "BBBB")
        #expect(job.notes.contains("Merged “album”: 2 copied, 1 already there, 1 kept both (different content, renamed)"))
    }

    @Test("Moving: the identical original goes to the Trash, the different one is renamed in")
    func move() async throws {
        let s = try Sandbox(); defer { s.cleanup() }
        try prepare(s)
        let engine = await s.engine(policy: { _ in ConflictDecision(.skip) })
        _ = try await engine.enqueue(.move(sources: [s.path("src/album")], destinationDir: s.path("dest")),
                                     options: JobOptions(conflictPolicy: .mergeKeepBoth))
        await engine.waitUntilIdle()
        #expect(s.names("dest/album") == ["a.jpg", "b 2.jpg", "b.jpg", "c.jpg"])
        #expect(!s.exists("src/album"))
        #expect(s.names("_Trash").contains("a.jpg"))
    }

    @Test("A single file with the same name: kept both when different")
    func topLevelFile() async throws {
        let s = try Sandbox(); defer { s.cleanup() }
        try s.file("src/n.txt", "new!")
        try s.file("dest/n.txt", "old!")
        try s.file("src/same.txt", "same")
        try s.file("dest/same.txt", "same")
        let engine = await s.engine(policy: { _ in ConflictDecision(.skip) })
        _ = try await engine.enqueue(.copy(sources: [s.path("src/n.txt"), s.path("src/same.txt")], destinationDir: s.path("dest")),
                                     options: JobOptions(conflictPolicy: .mergeKeepBoth))
        await engine.waitUntilIdle()
        #expect(s.names("dest") == ["n 2.txt", "n.txt", "same.txt"])
        #expect(s.read("dest/n 2.txt") == "new!")
    }
}

@Suite("Finding duplicates")
struct DuplicateFinderTests {
    func bytes(_ count: Int, seed: UInt8) -> Data {
        Data((0..<count).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ Int(seed)) })
    }

    @Test("The quick check ignores dates and compares bytes")
    func quickCheck() throws {
        let s = try Sandbox(); defer { s.cleanup() }
        let big = bytes(3 << 20, seed: 1)
        let a = s.path("a.bin"), b = s.path("b.bin"), c = s.path("c.bin")
        try big.write(to: a)
        try big.write(to: b)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 0)], ofItemAtPath: b.path)
        var changed = big
        changed[changed.count - 10] ^= 0xFF // inside the sampled end
        try changed.write(to: c)
        #expect(try FS.quickSameContents(a, b))
        #expect(try !FS.quickSameContents(a, c))
        try s.file("small1.txt", "hello")
        try s.file("small2.txt", "hellp")
        #expect(try !FS.quickSameContents(s.path("small1.txt"), s.path("small2.txt"))) // small files: every byte
    }

    @Test("Finds copies in subfolders, ignoring same-sized files that differ, tiny files and ._ files")
    func findsCopies() throws {
        let s = try Sandbox(); defer { s.cleanup() }
        let photo = bytes(5000, seed: 7)
        try photo.write(to: s.path("photo.jpg"))
        try s.dir("old/backup")
        try photo.write(to: s.path("old/backup/photo copy.jpg"))
        try photo.write(to: s.path("old/photo (1).jpg"))
        try bytes(5000, seed: 8).write(to: s.path("other.jpg"))   // same size, different
        try s.file("tiny1.txt", "x")
        try s.file("tiny2.txt", "x")
        try photo.write(to: s.path("old/._photo copy.jpg"))
        let groups = DuplicateFinder.find(in: s.root, options: .init(minimumSize: 100))
        #expect(groups.count == 1)
        let group = try #require(groups.first)
        #expect(Set(group.files.map(\.name)) == ["photo.jpg", "photo copy.jpg", "photo (1).jpg"])
        #expect(group.verified) // small enough that every byte was read
        #expect(group.extraBytes == 10_000)
        #expect(DuplicateFinder.keeper(of: group, rule: .bestName)?.name == "photo.jpg")
        #expect(DuplicateFinder.keeper(of: group, rule: .shallowest)?.name == "photo.jpg")

        let top = DuplicateFinder.find(in: s.root, options: .init(includeSubfolders: false, minimumSize: 100))
        #expect(top.isEmpty)
    }

    @Test("Big files that match on samples are flagged unverified; checking every byte tells them apart")
    func sampledMatchIsVerified() throws {
        let s = try Sandbox(); defer { s.cleanup() }
        let big = bytes(4 << 20, seed: 3)
        try big.write(to: s.path("one.mov"))
        try big.write(to: s.path("two.mov"))
        var sneaky = big
        sneaky[400 << 10] ^= 0xFF // between samples
        try sneaky.write(to: s.path("three.mov"))

        let groups = DuplicateFinder.find(in: s.root)
        #expect(groups.count == 1)
        let group = try #require(groups.first)
        #expect(group.files.count == 3)
        #expect(!group.verified)

        let checked = DuplicateFinder.verify(group)
        #expect(checked.count == 1)
        #expect(Set(checked[0].files.map(\.name)) == ["one.mov", "two.mov"])
        #expect(checked[0].verified)

        let exact = DuplicateFinder.find(in: s.root, options: .init(everyByte: true))
        #expect(exact.count == 1 && exact[0].files.count == 2 && exact[0].verified)
    }

    @Test("Names that look like copies")
    func copyNames() {
        for name in ["a 2.jpg", "a (1).jpg", "a copy.jpg", "a copy 3.jpg", "a - Copy.jpg", "a-1.jpg"] {
            #expect(DuplicateFinder.looksLikeCopy(name), "\(name)")
        }
        for name in ["a.jpg", "IMG_2041.jpg", "copyright.txt", "2024.pdf"] {
            #expect(!DuplicateFinder.looksLikeCopy(name), "\(name)")
        }
    }
}
