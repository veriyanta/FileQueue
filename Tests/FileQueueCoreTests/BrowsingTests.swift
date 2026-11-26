import Foundation
import Testing
@testable import FileQueueCore

@Suite("Folder browsing")
struct BrowsingTests {
    @Test("Lists items with kind, size and dates; hides dotfiles unless asked")
    func listing() throws {
        let s = try Sandbox(); defer { s.cleanup() }
        try s.file("b.txt", "12345")
        try s.file(".secret")
        try s.dir("Folder")
        try s.dir("Tool.app")
        try FileManager.default.createSymbolicLink(atPath: s.path("link").path, withDestinationPath: "b.txt")

        let entries = try DirectoryLister.list(s.root)
        let byName = Dictionary(uniqueKeysWithValues: entries.map { ($0.name, $0) })
        #expect(Set(byName.keys) == ["b.txt", "Folder", "Tool.app", "link"])
        #expect(byName["b.txt"]?.size == 5)
        #expect(byName["b.txt"]?.modified != nil)
        #expect(byName["Folder"]?.isFolder == true)
        #expect(byName["Folder"]?.size == nil)
        #expect(byName["Tool.app"]?.isFolder == false) // packages aren't browsable folders
        #expect(byName["Tool.app"]?.isPackage == true)
        #expect(byName["link"]?.isSymlink == true)

        #expect(try DirectoryLister.list(s.root, showHidden: true).contains { $0.name == ".secret" })
    }

    @Test("Sorting keeps folders first")
    func sorting() throws {
        let s = try Sandbox(); defer { s.cleanup() }
        try s.file("a.txt", "x")
        try s.file("c.txt", "xxxxx")
        try s.dir("b-folder")
        try s.dir("z-folder")
        let entries = try DirectoryLister.list(s.root).filter { $0.name != "_Trash" }

        let byName = DirectoryLister.sorted(entries, by: [KeyPathComparator(\.name, comparator: .localizedStandard)])
        #expect(byName.map(\.name) == ["b-folder", "z-folder", "a.txt", "c.txt"])

        let bySizeDesc = DirectoryLister.sorted(entries, by: [KeyPathComparator(\.sortSize, order: .reverse)])
        #expect(bySizeDesc.suffix(2).map(\.name) == ["c.txt", "a.txt"])
        #expect(Set(bySizeDesc.prefix(2).map(\.name)) == ["b-folder", "z-folder"])
    }

    @Test("Sorting by kind groups file types, names break ties, folders stay first")
    func sortByKind() throws {
        let s = try Sandbox(); defer { s.cleanup() }
        for n in ["b.txt", "z.jpg", "a.jpg", "c.png", "a.txt"] { try s.file(n) }
        try s.dir("Photos")
        let entries = try DirectoryLister.list(s.root).filter { $0.name != "_Trash" }
        #expect(entries.first { $0.name == "a.jpg" }?.kind.isEmpty == false)

        let byKind = DirectoryLister.sorted(entries, by: [KeyPathComparator(\.sortKind, comparator: .localizedStandard)])
        #expect(byKind.first?.name == "Photos")
        let files = byKind.dropFirst().map(\.name)
        // Same-type files sit together, in name order.
        for (x, y) in [("a.jpg", "z.jpg"), ("a.txt", "b.txt")] {
            let i = try #require(files.firstIndex(of: x)), j = try #require(files.firstIndex(of: y))
            #expect(j == i + 1)
        }
        let reversed = DirectoryLister.sorted(entries, by: [KeyPathComparator(\.sortKind, comparator: .localizedStandard, order: .reverse)])
        #expect(reversed.first?.name == "Photos")
        #expect(Array(reversed.dropFirst().map(\.kind)) == Array(byKind.dropFirst().map(\.kind).reversed()))
    }

    @Test("Natural name order (2 before 10)")
    func naturalOrder() throws {
        let s = try Sandbox(); defer { s.cleanup() }
        for n in ["IMG 10.jpg", "IMG 2.jpg", "IMG 1.jpg"] { try s.file(n) }
        let sorted = DirectoryLister.sorted(try DirectoryLister.list(s.root), by: [KeyPathComparator(\.name, comparator: .localizedStandard)])
        #expect(sorted.map(\.name) == ["IMG 1.jpg", "IMG 2.jpg", "IMG 10.jpg"])
    }

    @Test("Path menu lists parents up to / and stops")
    func ancestors() {
        #expect(DirectoryLister.ancestors(of: URL(fileURLWithPath: "/Volumes/USB Stick")).map(\.path)
            == ["/Volumes/USB Stick", "/Volumes", "/"])
        #expect(DirectoryLister.ancestors(of: URL(fileURLWithPath: "/")).map(\.path) == ["/"])
        #expect(DirectoryLister.ancestors(of: URL(fileURLWithPath: "/a/b/../c")).map(\.path) == ["/a/c", "/a", "/"])
    }

    @Test("New folder names don't clash")
    func newFolderName() throws {
        let s = try Sandbox(); defer { s.cleanup() }
        #expect(DirectoryLister.newFolderURL(in: s.root).lastPathComponent == "untitled folder")
        try s.dir("untitled folder")
        #expect(DirectoryLister.newFolderURL(in: s.root).lastPathComponent == "untitled folder 2")
    }

    @Test("The startup disk is listed first")
    func volumes() {
        let volumes = VolumeInfo.mounted()
        #expect(!volumes.isEmpty)
        #expect(volumes.first?.url.path == "/")
    }
}
