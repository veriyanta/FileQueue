import Foundation
import Testing
@testable import FileQueueCore

@Suite("Sampling before reading everything")
struct SamplingTests {
    func files(_ folders: [String: Int], ext: String = "jpg") -> [URL] {
        folders.keys.sorted().flatMap { folder in
            (0..<folders[folder]!).map { URL(fileURLWithPath: "/lib/\(folder)/IMG_\(String(format: "%04d", $0)).\(ext)") }
        }
    }

    @Test("A few files from every folder, spread through each folder")
    func perFolder() {
        let all = files(["2015": 100, "2016": 40, "2017": 2])
        let sample = MediaSampler.sample(all, perFolder: 3, maxTotal: 400)
        let byFolder = Dictionary(grouping: sample) { $0.deletingLastPathComponent().lastPathComponent }
        #expect(byFolder["2015"]?.count == 3)
        #expect(byFolder["2016"]?.count == 3)
        #expect(byFolder["2017"]?.count == 2)
        // Spread: first, middle, last.
        #expect(byFolder["2015"]!.map(\.lastPathComponent).sorted() == ["IMG_0000.jpg", "IMG_0050.jpg", "IMG_0099.jpg"])
    }

    @Test("With a cap, every folder still gets a turn before any gets more")
    func cap() {
        let all = files(Dictionary(uniqueKeysWithValues: (0..<50).map { ("f\($0)", 10) }))
        let sample = MediaSampler.sample(all, perFolder: 3, maxTotal: 60)
        #expect(sample.count == 60)
        #expect(Set(sample.map { $0.deletingLastPathComponent() }).count == 50) // all 50 folders represented
    }

    @Test("Photos and videos are preferred over other files in a folder")
    func prefersMedia() {
        let docs = (0..<20).map { URL(fileURLWithPath: "/lib/mixed/doc\($0).pdf") }
        let photos = [URL(fileURLWithPath: "/lib/mixed/a.jpg"), URL(fileURLWithPath: "/lib/mixed/b.mov")]
        let sample = MediaSampler.sample(docs + photos, perFolder: 3)
        #expect(Set(sample) == Set(photos))
        // A folder with no media is still sampled.
        #expect(MediaSampler.sample(docs, perFolder: 3).count == 3)
    }

    @Test("Basic info needs no file reading; kinds come from the extension")
    func basic() throws {
        let s = try Sandbox(); defer { s.cleanup() }
        try s.file("a.JPG", "not really a jpeg")
        let m = MetadataReader.readBasic(s.path("a.JPG"))
        #expect(m.kind == .image)
        #expect(m.modified != nil)
        #expect(m.taken == nil)
    }

    @Test("Which layouts need photo/video details")
    func needsDetails() {
        #expect(NameTemplate.needsDetails("{taken:yyyy}/{taken:MM}"))
        #expect(NameTemplate.needsDetails("{camera}"))
        #expect(NameTemplate.needsDetails("x {duration}"))
        #expect(!NameTemplate.needsDetails("{ext}"))
        #expect(!NameTemplate.needsDetails("{type}/{created:yyyy}"))
        #expect(!NameTemplate.needsDetails("{1}/{2} {name} {n:3}"))
    }

    @Test("Organize: files not read yet are 'not read', not sent to Unsorted — unless the layout doesn't need details")
    func organizeUnread() {
        let root = URL(fileURLWithPath: "/lib")
        let a = URL(fileURLWithPath: "/lib/a.jpg"), b = URL(fileURLWithPath: "/lib/b.jpg")
        var read = FileMetadata(); read.kind = .image; read.taken = Date(timeIntervalSince1970: 1_464_426_523)
        var basic = FileMetadata(); basic.kind = .image
        let md = [a: read, b: basic]

        let byDate = OrganizePlanner.plan(files: [a, b], root: root, options: .init(template: "{taken:yyyy}"), metadata: md, unread: [b])
        #expect(byDate.items[0].status == .ok)
        #expect(byDate.items[1].status == .notRead)
        #expect(byDate.notReadCount == 1)
        #expect(!OrganizeStatus.notRead.willMove)

        let byType = OrganizePlanner.plan(files: [a, b], root: root, options: .init(template: "{type}"), metadata: md, unread: [b])
        #expect(byType.items.allSatisfy { $0.status == .ok }) // no details needed
    }

    @Test("Rename: files not read yet are left alone and flagged")
    func renameUnread() {
        let a = URL(fileURLWithPath: "/d/a.jpg"), b = URL(fileURLWithPath: "/d/b.jpg")
        var read = FileMetadata(); read.kind = .image; read.taken = Date(timeIntervalSince1970: 1_464_426_523)
        let plan = RenameEngine.makePlan(files: [a, b], rules: [.metadata("{taken:yyyy}")],
                                         metadata: MetadataRenameTests.NoDisk(existing: ["a.jpg", "b.jpg"]),
                                         fileMetadata: [a: read], unread: [b])
        #expect(plan[0].status == .ok)
        #expect(plan[1].status == .notRead)
        #expect(!plan[1].status.isError)
        // Rules that don't need details aren't held back.
        let byName = RenameEngine.makePlan(files: [a, b], rules: [.prefix("x-")],
                                           metadata: MetadataRenameTests.NoDisk(), unread: [a, b])
        #expect(byName.allSatisfy { $0.status == .ok })
    }
}
