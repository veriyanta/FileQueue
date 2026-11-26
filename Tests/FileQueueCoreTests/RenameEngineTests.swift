import Foundation
import Testing
@testable import FileQueueCore

struct FakeMetadata: FileMetadataProviding {
    var folders: Set<String> = []
    var existing: [String] = []
    var caseSensitive = false
    var fixedDate = Date(timeIntervalSince1970: 1_700_000_000) // 2023-11-14

    func isPlainFolder(_ url: URL) -> Bool { folders.contains(url.lastPathComponent) }
    func date(_ source: RenameRule.DateSource, of url: URL) -> Date? { fixedDate }
    func existingNames(in directory: URL) -> [String] { existing }
    func isCaseSensitive(_ directory: URL) -> Bool { caseSensitive }
}

@Suite("Batch rename engine")
struct RenameEngineTests {
    func names(_ files: [String], _ rules: [RenameRule], _ meta: FakeMetadata = FakeMetadata()) -> [String] {
        var meta = meta
        if meta.existing.isEmpty { meta.existing = files }
        return RenameEngine.makePlan(files: files.map { url("/d/\($0)") }, rules: rules, metadata: meta).map(\.proposedName)
    }

    func plan(_ files: [String], _ rules: [RenameRule], _ meta: FakeMetadata = FakeMetadata()) -> [RenamePlanItem] {
        var meta = meta
        if meta.existing.isEmpty { meta.existing = files }
        return RenameEngine.makePlan(files: files.map { url("/d/\($0)") }, rules: rules, metadata: meta)
    }

    @Test func replacePlainCaseInsensitive() {
        #expect(names(["IMG_001.jpg"], [.replace("img_", with: "Trip ")]) == ["Trip 001.jpg"])
        #expect(names(["IMG_001.jpg"], [.replace("img_", with: "x", caseSensitive: true)]) == ["IMG_001.jpg"])
    }

    @Test func replaceRegexWithGroups() {
        #expect(names(["2024-05-01 notes.txt"], [.replace(#"(\d+)-(\d+)-(\d+)"#, with: "$3.$2.$1", regex: true)]) == ["01.05.2024 notes.txt"])
    }

    @Test func badRegexIsInvalid() {
        guard case .invalid = plan(["a.txt"], [.replace("(", with: "", regex: true)])[0].status else {
            Issue.record("expected invalid"); return
        }
    }

    @Test func prefixSuffixInsertRemove() {
        #expect(names(["a.txt"], [.prefix("pre-"), .suffix("-post")]) == ["pre-a-post.txt"])
        #expect(names(["abcdef.txt"], [.insert("XX", at: 2)]) == ["abXXcdef.txt"])
        #expect(names(["abcdef.txt"], [.insert("XX", at: 99)]) == ["abcdefXX.txt"])
        #expect(names(["abcdef.txt"], [.remove(from: 1, count: 2)]) == ["adef.txt"])
        #expect(names(["abc.txt"], [.remove(from: 1, count: 99)]) == ["a.txt"])
    }

    @Test func caseStyles() {
        #expect(names(["Hello World.TXT"], [.changeCase(.lower)]) == ["hello world.TXT"])
        #expect(names(["hello world.txt"], [.changeCase(.upper)]) == ["HELLO WORLD.txt"])
        #expect(names(["hello world.txt"], [.changeCase(.title)]) == ["Hello World.txt"])
        #expect(names(["hELLO wORLD.txt"], [.changeCase(.sentence)]) == ["Hello world.txt"])
    }

    @Test func sequenceNumbers() {
        let files = ["a.jpg", "b.jpg", "c.jpg"]
        #expect(names(files, [.sequence(start: 1, step: 1, padding: 3)]) == ["a_001.jpg", "b_002.jpg", "c_003.jpg"])
        #expect(names(files, [.replace(#"^.*$"#, with: "Trip", regex: true), .sequence(start: 10, step: 5, padding: 2, placement: .suffix, separator: " ")])
            == ["Trip 10.jpg", "Trip 15.jpg", "Trip 20.jpg"])
    }

    @Test func dates() {
        #expect(names(["a.jpg"], [.date(.modified, format: "yyyy-MM-dd", placement: .prefix, separator: " ")]).first?.hasPrefix("2023-11-1") == true)
    }

    @Test func extensions() {
        #expect(names(["a.jpeg"], [.setExtension("jpg")]) == ["a.jpg"])
        #expect(names(["a.jpeg"], [.setExtension(".JPG")]) == ["a.JPG"])
        #expect(names(["a.jpeg"], [.setExtension("")]) == ["a"])
    }

    @Test func plainFoldersHaveNoExtension() {
        var meta = FakeMetadata()
        meta.folders = ["My.Folder"]
        #expect(names(["My.Folder"], [.suffix("!")], meta) == ["My.Folder!"])
        #expect(names(["App.app"], [.suffix("!")], meta) == ["App!.app"])
    }

    @Test func trim() {
        #expect(names(["  spaced  .txt"], [.trimWhitespace]) == ["spaced.txt"])
    }

    @Test func disabledRulesAreIgnored() {
        var rule = RenameRule.prefix("x")
        rule.isEnabled = false
        #expect(plan(["a.txt"], [rule])[0].status == .unchanged)
    }

    @Test func collisionsWithinBatch() {
        let p = plan(["a1.txt", "a2.txt", "b.txt"], [.replace(#"\d"#, with: "", regex: true)])
        #expect(p[0].status == .collidesWithinBatch)
        #expect(p[1].status == .collidesWithinBatch)
        #expect(p[2].status == .unchanged)
    }

    @Test func unchangedFileBlocksAnotherTarget() {
        // "x.txt" stays; "y.txt" → "x.txt" would clash with it.
        let p = plan(["x.txt", "y.txt"], [.replace("y", with: "x")])
        #expect(p.allSatisfy { $0.status == .collidesWithinBatch })
    }

    @Test func collisionWithExistingFile() {
        var meta = FakeMetadata()
        meta.existing = ["a.txt", "b.txt"] // b.txt is not part of the batch
        let p = plan(["a.txt"], [.replace("a", with: "B")], meta)
        #expect(p[0].status == .collidesWithExisting) // case-insensitive disk
        meta.caseSensitive = true
        #expect(plan(["a.txt"], [.replace("a", with: "B")], meta)[0].status == .ok)
    }

    @Test func swapsAreAllowed() {
        // a→b and b→a: the old names are being renamed away, so there is no clash.
        let p = RenameEngine.makePlan(
            files: [url("/d/a.txt"), url("/d/b.txt")],
            rules: [.replace(#"^(a|b)$"#, with: "x", regex: true)], metadata: FakeMetadata(existing: ["a.txt", "b.txt"]))
        #expect(p.allSatisfy { $0.status == .collidesWithinBatch }) // both become x.txt
        var meta = FakeMetadata(existing: ["a.txt", "b.txt"])
        meta.caseSensitive = false
        let swap = [
            RenamePlanItem(original: url("/d/a.txt"), proposedName: "b.txt", status: .ok),
            RenamePlanItem(original: url("/d/b.txt"), proposedName: "a.txt", status: .ok),
        ]
        var checked = swap
        RenameEngine.markCollisions(&checked, metadata: meta)
        #expect(checked == swap)
    }

    @Test func caseOnlyRenameIsNotACollision() {
        #expect(plan(["photo.jpg"], [.changeCase(.upper)])[0].status == .ok)
    }

    @Test func unicodeNormalization() {
        let composed = "caf\u{00E9}.txt"     // é as one scalar
        let decomposed = "cafe\u{0301}.txt"  // e + combining accent
        let p = plan(["one.txt", "two.txt"], [.replace(#"one"#, with: "caf\u{00E9}", regex: true), .replace("two", with: "cafe\u{0301}")])
        #expect(p[0].proposedName == composed)
        #expect(p[1].proposedName == decomposed)
        #expect(p.allSatisfy { $0.status == .collidesWithinBatch })
    }

    @Test("Invalid results are flagged", arguments: [":", "/"])
    func invalidCharacters(char: String) {
        guard case .invalid = plan(["a.txt"], [.suffix(char)])[0].status else { Issue.record("expected invalid"); return }
    }

    @Test func emptyNameIsInvalid() {
        guard case .invalid = plan(["abc"], [.remove(from: 0, count: 3)])[0].status else { Issue.record("expected invalid"); return }
    }

    @Test func rulesRoundTripAsJSON() throws {
        let rules: [RenameRule] = [.prefix("x"), .sequence(), .date(.exif)]
        let data = try JSONEncoder().encode(rules)
        #expect(try JSONDecoder().decode([RenameRule].self, from: data) == rules)
    }
}
