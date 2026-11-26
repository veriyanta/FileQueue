import CoreGraphics
import Foundation
import Testing
@testable import FileQueueCore

@Suite("Disk map")
struct DiskUsageTests {
    @Test("Treemap: blocks fill the area exactly, stay inside it, don't overlap, and are proportional")
    func treemapGeometry() {
        let values: [Double] = [60, 30, 25, 12, 8, 6, 3, 1, 0]
        let rect = CGRect(x: 10, y: 20, width: 600, height: 400)
        let rects = Treemap.layout(values, in: rect)
        #expect(rects.count == values.count)
        #expect(rects.last == .zero) // zero value → no block
        let total = values.reduce(0, +)
        for (v, r) in zip(values, rects) where v > 0 {
            #expect(abs(Double(r.width * r.height) - v / total * 240_000) < 1)
            #expect(r.minX >= rect.minX - 0.001 && r.maxX <= rect.maxX + 0.001)
            #expect(r.minY >= rect.minY - 0.001 && r.maxY <= rect.maxY + 0.001)
        }
        for a in rects.indices where values[a] > 0 {
            for b in rects.indices where b > a && values[b] > 0 {
                let overlap = rects[a].intersection(rects[b])
                #expect(overlap.isNull || overlap.width * overlap.height < 0.01)
            }
        }
    }

    @Test("Treemap: equal sizes give near-square blocks")
    func treemapSquare() {
        let rects = Treemap.layout(Array(repeating: 1, count: 16), in: CGRect(x: 0, y: 0, width: 400, height: 400))
        for r in rects {
            let ratio = max(r.width / r.height, r.height / r.width)
            #expect(ratio < 1.6)
        }
    }

    @Test("Scanner: sizes add up, largest first, kinds recognised, links ignored")
    func scan() throws {
        let s = try Sandbox(); defer { s.cleanup() }
        try s.file("root/big.mov", String(repeating: "x", count: 300_000))
        try s.file("root/photos/a.jpg", String(repeating: "x", count: 100_000))
        try s.file("root/photos/b.jpg", String(repeating: "x", count: 50_000))
        try s.file("root/notes.txt", "hello")
        try s.file("root/.hidden", String(repeating: "x", count: 20_000))
        try FileManager.default.createSymbolicLink(atPath: s.path("root/link").path, withDestinationPath: "big.mov")
        let root = DiskUsageScanner.scan(s.path("root"))

        #expect(root.children.map(\.name) == ["big.mov", "photos", ".hidden", "notes.txt"])
        #expect(root.children[0].kind == .video)
        #expect(root.children[1].kind == .folder && root.children[1].children.allSatisfy { $0.kind == .image })
        #expect(root.children[3].kind == .document)
        #expect(root.fileCount == 5)
        #expect(root.size == root.children.reduce(0) { $0 + $1.size })
        #expect(root.children[1].size >= 150_000) // allocated size is at least the content
        #expect(root.children[1].children[0].path.map(\.name) == [root.name, "photos", "a.jpg"])
    }

    @Test("Scanner: many small items are grouped so memory stays bounded")
    func grouping() throws {
        let s = try Sandbox(); defer { s.cleanup() }
        for i in 0..<30 { try s.file("many/f\(i).txt", String(repeating: "x", count: 5000 + i * 100)) }
        let root = DiskUsageScanner.scan(s.path("many"), maxChildren: 10)
        #expect(root.children.count == 10)
        #expect(root.children.last?.kind == .group)
        #expect(root.children.last?.name == "21 smaller items")
        #expect(root.fileCount == 30)
    }

    @Test("Scanner: an unreadable folder is marked, the rest still measured")
    func unreadable() throws {
        let s = try Sandbox(); defer { chmod(s.path("root/locked").path, 0o755); s.cleanup() }
        try s.file("root/locked/x.txt", "x")
        try s.file("root/ok.txt", "ok")
        chmod(s.path("root/locked").path, 0o000)
        let root = DiskUsageScanner.scan(s.path("root"))
        #expect(root.unreadable)
        #expect(root.children.first { $0.name == "locked" }?.unreadable == true)
        #expect(root.fileCount == 1)
    }

    @Test("Scanner can be cancelled")
    func cancel() throws {
        let s = try Sandbox(); defer { s.cleanup() }
        for i in 0..<50 { try s.file("d\(i)/f.txt") }
        let root = DiskUsageScanner.scan(s.root, isCancelled: { true })
        #expect(root.children.isEmpty)
    }
}
