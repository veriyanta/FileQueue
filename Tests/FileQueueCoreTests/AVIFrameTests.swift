import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import FileQueueCore

@Suite struct AVIFrameTests {
    /// Optional check against real files: FQ_AVI_DIR=/path [FQ_OUT=/dir] swift test --filter AVIFrame
    @Test func realFiles() throws {
        guard let dir = ProcessInfo.processInfo.environment["FQ_AVI_DIR"] else { return }
        let out = ProcessInfo.processInfo.environment["FQ_OUT"]
        let files = FileManager.default.enumerator(at: URL(fileURLWithPath: dir), includingPropertiesForKeys: nil)!
            .compactMap { $0 as? URL }.filter { $0.pathExtension.lowercased() == "avi" && !$0.lastPathComponent.hasPrefix("._") }
        var byCodec: [String: (ok: Int, total: Int)] = [:]
        let start = Date()
        for file in files {
            let head = (try? FileHandle(forReadingFrom: file).read(upToCount: 64 << 10)) ?? Data()
            var codec = "?"
            if let r = head.range(of: Data("hdrl".utf8)) {
                let body = Data(head[r.upperBound...])
                if let s = AVIFrame.videoStream(inHeaderList: body) { codec = s.isBitmap ? "bitmap\(s.compression)" : s.fourCC }
            }
            let image = AVIFrame.image(at: file)
            var entry = byCodec[codec] ?? (0, 0)
            entry.total += 1
            if let image {
                entry.ok += 1
                if let out, entry.ok <= 2 {
                    let dest = URL(fileURLWithPath: out).appendingPathComponent("\(codec)-\(file.deletingPathExtension().lastPathComponent).png")
                    if let d = CGImageDestinationCreateWithURL(dest as CFURL, "public.png" as CFString, 1, nil) {
                        CGImageDestinationAddImage(d, image, nil); CGImageDestinationFinalize(d)
                    }
                }
            }
            byCodec[codec] = entry
        }
        print("AVI frames in \(String(format: "%.1f", Date().timeIntervalSince(start)))s: \(byCodec.sorted { $0.value.total > $1.value.total }.map { "\($0.key) \($0.value.ok)/\($0.value.total)" })")
    }
}

/// Writes a minimal AVI with one uncompressed 24-bit frame.
private func bitmapAVI(width: Int, height: Int, bgr: (UInt8, UInt8, UInt8)) -> Data {
    func u32(_ v: Int) -> Data { withUnsafeBytes(of: UInt32(v).littleEndian) { Data($0) } }
    func u16(_ v: Int) -> Data { withUnsafeBytes(of: UInt16(v).littleEndian) { Data($0) } }
    func chunk(_ id: String, _ body: Data) -> Data { Data(id.utf8) + u32(body.count) + body + (body.count % 2 == 1 ? Data([0]) : Data()) }
    func list(_ type: String, _ body: Data) -> Data { chunk("LIST", Data(type.utf8) + body) }
    let rowBytes = (width * 3 + 3) & ~3
    var pixels = Data()
    for _ in 0..<height {
        for _ in 0..<width { pixels += Data([bgr.0, bgr.1, bgr.2]) }
        pixels += Data(count: rowBytes - width * 3)
    }
    var bih = u32(40) + u32(width) + u32(height)
    bih += u16(1) + u16(24)
    bih += u32(0) + u32(pixels.count)
    bih += Data(count: 16)
    let strh = Data("vids".utf8) + Data(count: 52)
    let hdrl = list("hdrl", chunk("avih", Data(count: 56)) + list("strl", chunk("strh", strh) + chunk("strf", bih)))
    let movi = list("movi", chunk("00dc", pixels))
    let body = Data("AVI ".utf8) + hdrl + movi
    return Data("RIFF".utf8) + u32(body.count) + body
}

extension AVIFrameTests {
    @Test func decodesUncompressedFrames() throws {
        let sandbox = try Sandbox()
        defer { try? FileManager.default.removeItem(at: sandbox.root) }
        let file = sandbox.path("capture.avi")
        try bitmapAVI(width: 33, height: 20, bgr: (10, 20, 230)).write(to: file) // red
        let image = try #require(AVIFrame.image(at: file))
        #expect(image.width == 33 && image.height == 20)
        var px = [UInt8](repeating: 0, count: 4)
        let ctx = CGContext(data: &px, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(image, in: CGRect(x: -16, y: -10, width: 33, height: 20))
        #expect(px[0] > 180 && px[1] < 80 && px[2] < 80, "got \(px)")
    }

    @Test func findsMPEG4SetupAndIntraFrames() {
        // VOS, VO, VOL, then an I-VOP; a P-VOP on its own.
        let vos = Data([0, 0, 1, 0xB0, 0x01]), vo = Data([0, 0, 1, 0xB5, 0x09]), vol = Data([0, 0, 1, 0x20, 0x08, 0x86, 0x84])
        let iVOP = Data([0, 0, 1, 0xB6, 0x10, 0xFF]), pVOP = Data([0, 0, 1, 0xB6, 0x50, 0xFF])
        let first = vos + vo + vol + iVOP
        #expect(MPEG4Part2.config(in: first) == vos + vo + vol)
        #expect(MPEG4Part2.isIntra(first))
        #expect(!MPEG4Part2.isIntra(pVOP))
        #expect(MPEG4Part2.config(in: pVOP) == nil)
        #expect(MPEG4Part2.formatDescription(config: vos + vo + vol, width: 640, height: 480) != nil)
    }

    @Test func notAVideoGivesNil() throws {
        let sandbox = try Sandbox()
        defer { try? FileManager.default.removeItem(at: sandbox.root) }
        #expect(AVIFrame.image(at: try sandbox.file("fake.avi", "RIFF....AVI LIST")) == nil)
    }
}
