import Foundation
import Testing
@testable import FileQueueCore

@Suite("Folder size limit (001, 002…)", .serialized)
struct FolderLimitTests {
    let root = URL(fileURLWithPath: "/lib")

    func files(_ n: Int, in folder: String = "/lib") -> [URL] {
        (1...n).map { URL(fileURLWithPath: "\(folder)/scan-\(String(format: "%04d", $0)).jpg") }
    }

    func rel(_ plan: OrganizePlanner.Plan) -> [String] {
        plan.items.map { OrganizePlanner.relativePath($0.destination, root) }
    }

    /// Pretends these folders exist with these items.
    func lister(_ contents: [String: [String]]) -> OrganizePlanner.FolderLister {
        { dir in contents[dir.standardizedFileURL.path] ?? [] }
    }

    @Test("Unsorted with more files than the limit is split into 001, 002, 003")
    func splitsFallback() {
        let plan = OrganizePlanner.plan(files: files(10), root: root,
                                        options: .init(template: "{taken:yyyy}", maxPerFolder: 4), metadata: [:], lister: lister([:]))
        #expect(rel(plan) == [
            "Unsorted/001/scan-0001.jpg", "Unsorted/001/scan-0002.jpg", "Unsorted/001/scan-0003.jpg", "Unsorted/001/scan-0004.jpg",
            "Unsorted/002/scan-0005.jpg", "Unsorted/002/scan-0006.jpg", "Unsorted/002/scan-0007.jpg", "Unsorted/002/scan-0008.jpg",
            "Unsorted/003/scan-0009.jpg", "Unsorted/003/scan-0010.jpg",
        ])
        #expect(plan.items.allSatisfy { if case .fallback = $0.status { return true }; return false })
    }

    @Test("Folders under the limit aren't split")
    func underLimit() {
        let plan = OrganizePlanner.plan(files: files(4), root: root,
                                        options: .init(template: "{taken:yyyy}", maxPerFolder: 4), metadata: [:], lister: lister([:]))
        #expect(rel(plan).allSatisfy { $0.hasPrefix("Unsorted/scan-") })
        let unlimited = OrganizePlanner.plan(files: files(50), root: root,
                                             options: .init(template: "{taken:yyyy}", maxPerFolder: 0), metadata: [:], lister: lister([:]))
        #expect(rel(unlimited).allSatisfy { $0.hasPrefix("Unsorted/scan-") })
    }

    @Test("Files already in the folder count toward the limit")
    func existingCount() {
        let plan = OrganizePlanner.plan(files: files(2), root: root,
                                        options: .init(template: "{taken:yyyy}", maxPerFolder: 4), metadata: [:],
                                        lister: lister(["/lib/Unsorted": ["old1.jpg", "old2.jpg", "old3.jpg"]]))
        #expect(rel(plan) == ["Unsorted/001/scan-0001.jpg", "Unsorted/001/scan-0002.jpg"])
    }

    @Test("Existing numbered folders are filled up before new ones are made")
    func continuesNumbering() {
        let plan = OrganizePlanner.plan(files: files(5), root: root,
                                        options: .init(template: "{taken:yyyy}", maxPerFolder: 4), metadata: [:],
                                        lister: lister([
                                            "/lib/Unsorted": ["001", "002"],
                                            "/lib/Unsorted/001": ["a", "b", "c", "d"],
                                            "/lib/Unsorted/002": ["e"],
                                        ]))
        #expect(rel(plan) == ["Unsorted/002/scan-0001.jpg", "Unsorted/002/scan-0002.jpg", "Unsorted/002/scan-0003.jpg",
                              "Unsorted/003/scan-0004.jpg", "Unsorted/003/scan-0005.jpg"])
    }

    @Test("Any destination folder is limited, not just Unsorted")
    func anyFolder() {
        var m = FileMetadata(); m.kind = .image; m.taken = Date(timeIntervalSince1970: 1_464_426_523)
        let list = files(6)
        let md = Dictionary(uniqueKeysWithValues: list.map { ($0, m) })
        let plan = OrganizePlanner.plan(files: list, root: root, options: .init(template: "{taken:yyyy}", maxPerFolder: 5),
                                        metadata: md, lister: lister([:]))
        #expect(rel(plan).filter { $0.hasPrefix("2016/001/") }.count == 5)
        #expect(rel(plan).filter { $0.hasPrefix("2016/002/") }.count == 1)
    }

    @Test("Only split: a big folder's own files go into numbered subfolders; ones already there stay")
    func splitInPlace() {
        let unsorted = URL(fileURLWithPath: "/lib/Unsorted")
        let flat = files(6, in: "/lib/Unsorted")
        let alreadySplit = [URL(fileURLWithPath: "/lib/Unsorted/001/x.jpg"), URL(fileURLWithPath: "/lib/Unsorted/001/y.jpg")]
        let plan = OrganizePlanner.plan(
            files: alreadySplit + flat, root: unsorted, options: .init(template: ".", maxPerFolder: 4), metadata: [:],
            lister: lister([
                "/lib/Unsorted": ["001"] + flat.map(\.lastPathComponent),
                "/lib/Unsorted/001": ["x.jpg", "y.jpg"],
            ]))
        #expect(plan.error == nil)
        #expect(plan.items[0].status == .unchanged && plan.items[1].status == .unchanged)
        let moved = plan.items.dropFirst(2).map { OrganizePlanner.relativePath($0.destination, unsorted) }
        #expect(moved == ["001/scan-0001.jpg", "001/scan-0002.jpg", "002/scan-0003.jpg", "002/scan-0004.jpg",
                          "002/scan-0005.jpg", "002/scan-0006.jpg"])

        // A small folder: nothing to do.
        let small = OrganizePlanner.plan(files: files(3, in: "/lib/Unsorted"), root: unsorted, options: .init(template: ".", maxPerFolder: 4),
                                         metadata: [:], lister: lister(["/lib/Unsorted": files(3).map(\.lastPathComponent)]))
        #expect(small.items.allSatisfy { $0.status == .unchanged })
        // The same folder written with a trailing slash behaves the same.
        let slashed = OrganizePlanner.plan(files: files(3, in: "/lib/Unsorted"), root: URL(fileURLWithPath: "/lib/Unsorted/", isDirectory: true),
                                           options: .init(template: ".", maxPerFolder: 4), metadata: [:],
                                           lister: lister(["/lib/Unsorted": files(3).map(\.lastPathComponent)]))
        #expect(slashed.items.allSatisfy { $0.status == .unchanged })
        #expect(OrganizePlanner.plan(files: [], root: root, options: .init(template: ""), metadata: [:]).error != nil)
    }

    @Test("End to end: splitting a real folder with a move")
    func endToEnd() async throws {
        let s = try Sandbox(); defer { s.cleanup() }
        for i in 1...7 { try s.file("Unsorted/f\(i).txt", "\(i)") }
        let root = s.path("Unsorted")
        let list = FileExpander.expand([root], recursive: true)
        let plan = OrganizePlanner.plan(files: list, root: root, options: .init(template: ".", maxPerFolder: 3), metadata: [:])
        let engine = await s.engine()
        let id = try await engine.enqueue(.organize(items: plan.items, move: true, cleanUpIn: root))
        await engine.waitUntilIdle()
        #expect(try #require(await engine.job(id)).state == .completed)
        #expect(s.names("Unsorted") == ["001", "002", "003"])
        #expect(s.names("Unsorted/001").count == 3 && s.names("Unsorted/002").count == 3 && s.names("Unsorted/003").count == 1)
        #expect(OrganizePlanner.numberedFolderName(1000) == "1000")
    }
}
