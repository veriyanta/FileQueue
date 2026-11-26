import Foundation
import Testing
@testable import FileQueueCore

@Suite("Empty folders")
struct EmptyFolderTests {
    func names(_ urls: [URL], in s: Sandbox) -> [String] {
        let base = s.root.standardizedFileURL.path + "/"
        return urls.map { String($0.standardizedFileURL.path.dropFirst(base.count)) }
    }

    @Test("Finds empty and clutter-only folders, outermost only; keeps anything with content")
    func finds() throws {
        let s = try Sandbox(); defer { s.cleanup() }
        _ = try s.dir("Empty")
        _ = try s.file("Clutter/.DS_Store")
        _ = try s.file("Clutter/Thumbs.db")
        _ = try s.file("Clutter/._photo.jpg")
        _ = try s.dir("Nested/a/b/c")
        _ = try s.file("Nested/a/.DS_Store")
        _ = try s.file("Mixed/keep.txt")
        _ = try s.dir("Mixed/gone")
        _ = try s.file("HiddenFile/.env")
        _ = try s.dir("HasHiddenFolder/.git")
        _ = try s.dir("Tool.app")
        try FileManager.default.createSymbolicLink(at: s.path("Link"), withDestinationURL: s.path("Empty"))
        _ = try s.dir("LinkHolder")
        try FileManager.default.createSymbolicLink(at: s.path("LinkHolder/l"), withDestinationURL: s.path("Mixed"))

        let found = names(EmptyFolderFinder.find(in: s.root).folders, in: s).filter { !$0.hasPrefix("_Trash") }
        #expect(found == ["Clutter", "Empty", "Mixed/gone", "Nested"])
    }

    @Test("The scanned folder itself is never returned, even when empty")
    func notRoot() throws {
        let s = try Sandbox(); defer { s.cleanup() }
        let inner = try s.dir("Only")
        #expect(EmptyFolderFinder.find(in: inner).folders.isEmpty)
    }

    @Test("Re-check before trashing notices new content")
    func recheck() throws {
        let s = try Sandbox(); defer { s.cleanup() }
        let d = try s.dir("A/B")
        #expect(EmptyFolderFinder.isStillEmpty(s.path("A")))
        _ = try s.file("A/B/new.txt")
        #expect(!EmptyFolderFinder.isStillEmpty(s.path("A")))
        #expect(!EmptyFolderFinder.isStillEmpty(d))
        #expect(!EmptyFolderFinder.isStillEmpty(s.path("missing")))
    }
}
