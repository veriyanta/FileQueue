import CoreGraphics
import ImageIO
import Foundation
import Testing
@testable import FileQueueCore

@Suite struct MatroskaFrameTests {
    /// Optional check against real files: FQ_MKV_DIR=/path swift test --filter MatroskaFrame
    @Test func realFiles() throws {
        guard let dir = ProcessInfo.processInfo.environment["FQ_MKV_DIR"] else { return }
        let files = FileManager.default.enumerator(at: URL(fileURLWithPath: dir), includingPropertiesForKeys: nil)!
            .compactMap { $0 as? URL }.filter { $0.pathExtension.lowercased() == "mkv" }
        var ok = 0, failed: [String] = []
        let start = Date()
        for file in files {
            if let image = MatroskaFrame.image(at: file), image.width > 0 { ok += 1 } else { failed.append(file.lastPathComponent) }
        }
        print("MKV frames: \(ok)/\(files.count) in \(String(format: "%.1f", Date().timeIntervalSince(start)))s; failed: \(failed.prefix(30))")
    }
}

extension MatroskaFrameTests {
    /// FQ_MKV_FILES="a.mkv|b.mkv" FQ_OUT=/dir: writes frames as PNG and prints why files fail.
    @Test func dumpFrames() throws {
        guard let list = ProcessInfo.processInfo.environment["FQ_MKV_FILES"], let out = ProcessInfo.processInfo.environment["FQ_OUT"] else { return }
        for path in list.split(separator: "|").map(String.init) {
            let url = URL(fileURLWithPath: path)
            let head = try FileHandle(forReadingFrom: url).read(upToCount: 4 << 20) ?? Data()
            let track = MatroskaFrame.videoTrack(in: head)
            print("TRACK \(url.lastPathComponent): \(track.map { "\($0.codecID) #\($0.number) \($0.width)x\($0.height) priv=\($0.codecPrivate.count) comp=\(String(describing: $0.compression)) strip=\($0.strippedHeader.count)" } ?? "none")")
            guard let image = MatroskaFrame.image(at: url) else { print("  no frame"); continue }
            let dest = URL(fileURLWithPath: out).appendingPathComponent(url.deletingPathExtension().lastPathComponent + ".png")
            let d = CGImageDestinationCreateWithURL(dest as CFURL, "public.png" as CFString, 1, nil)!
            CGImageDestinationAddImage(d, image, nil)
            CGImageDestinationFinalize(d)
        }
    }
}

// MARK: - Real H.264 MKVs made in the test

import CoreMedia
import CoreVideo
import VideoToolbox

private struct EncodeError: Error { let reason: String }

/// One solid-colour frame encoded with macOS's H.264 encoder.
private struct EncodedFrame {
    let avcC: Data
    /// 4-byte length-prefixed NAL units, as Matroska stores them.
    let frame: Data
    let width = 320, height = 240

    init(red: UInt8, green: UInt8, blue: UInt8) throws {
        var session: VTCompressionSession?
        guard VTCompressionSessionCreate(allocator: nil, width: 320, height: 240, codecType: kCMVideoCodecType_H264,
                                         encoderSpecification: nil, imageBufferAttributes: nil, compressedDataAllocator: nil,
                                         outputCallback: nil, refcon: nil, compressionSessionOut: &session) == noErr,
              let session else { throw EncodeError(reason: "no encoder") }
        defer { VTCompressionSessionInvalidate(session) }
        var pixels: CVPixelBuffer?
        CVPixelBufferCreate(nil, 320, 240, kCVPixelFormatType_32BGRA, nil, &pixels)
        guard let pixels else { throw EncodeError(reason: "no buffer") }
        CVPixelBufferLockBaseAddress(pixels, [])
        let base = CVPixelBufferGetBaseAddress(pixels)!.assumingMemoryBound(to: UInt8.self)
        let row = CVPixelBufferGetBytesPerRow(pixels)
        for y in 0..<240 { for x in 0..<320 { let p = base + y * row + x * 4; p[0] = blue; p[1] = green; p[2] = red; p[3] = 255 } }
        CVPixelBufferUnlockBaseAddress(pixels, [])

        final class Box: @unchecked Sendable { var sample: CMSampleBuffer? }
        let box = Box()
        let props = [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary
        VTCompressionSessionEncodeFrame(session, imageBuffer: pixels, presentationTimeStamp: .zero, duration: .invalid,
                                        frameProperties: props, infoFlagsOut: nil) { _, _, sample in box.sample = sample }
        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
        guard let sample = box.sample, let format = CMSampleBufferGetFormatDescription(sample),
              let atoms = CMFormatDescriptionGetExtension(format, extensionKey: kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms) as? [String: Any],
              let avcC = atoms["avcC"] as? Data, let block = CMSampleBufferGetDataBuffer(sample) else { throw EncodeError(reason: "no sample") }
        var data = Data(count: CMBlockBufferGetDataLength(block))
        _ = data.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: $0.count, destination: $0.baseAddress!) }
        self.avcC = avcC
        self.frame = data
    }

    /// The same frame with start codes and the SPS/PPS in front, as some ffmpeg builds write it.
    var annexBWithParameterSets: Data {
        // avcC: 5 bytes, then SPS count (low 5 bits), [len16, sps], PPS count, [len16, pps].
        let a = [UInt8](avcC)
        var i = 6
        let spsLen = Int(a[i]) << 8 | Int(a[i + 1]); let sps = a[(i + 2)..<(i + 2 + spsLen)]; i += 2 + spsLen + 1
        let ppsLen = Int(a[i]) << 8 | Int(a[i + 1]); let pps = a[(i + 2)..<(i + 2 + ppsLen)]
        var out = Data([0, 0, 0, 1]) + sps + Data([0, 0, 0, 1]) + pps
        for unit in MatroskaFrame.nalUnits(frame) { out += Data([0, 0, 0, 1]) + unit }
        return out
    }
}

/// Writes a minimal but valid Matroska file.
private enum MKVWriter {
    static func size(_ n: Int) -> Data {
        var bytes = Data([0x01]); var v = UInt64(n)
        var tail = [UInt8](repeating: 0, count: 7)
        for k in (0..<7).reversed() { tail[k] = UInt8(v & 0xFF); v >>= 8 }
        bytes.append(contentsOf: tail)
        return bytes
    }
    static func element(_ id: [UInt8], _ payload: Data) -> Data { Data(id) + size(payload.count) + payload }
    static func uint(_ id: [UInt8], _ v: UInt64) -> Data { element(id, Data((0..<8).reversed().map { UInt8((v >> (UInt64($0) * 8)) & 0xFF) })) }
    static func string(_ id: [UInt8], _ s: String) -> Data { element(id, Data(s.utf8)) }

    static func file(codecPrivate: Data?, frame: Data, strippedHeader: Data? = nil, width: Int, height: Int) -> Data {
        let header = element([0x1A, 0x45, 0xDF, 0xA3], string([0x42, 0x82], "matroska"))
        var entry = uint([0xD7], 1) + uint([0x83], 1) + string([0x86], "V_MPEG4/ISO/AVC")
        if let codecPrivate { entry += element([0x63, 0xA2], codecPrivate) }
        entry += element([0xE0], uint([0xB0], UInt64(width)) + uint([0xBA], UInt64(height)))
        if let strippedHeader {
            let compression = element([0x50, 0x34], uint([0x42, 0x54], 3) + element([0x42, 0x55], strippedHeader))
            entry += element([0x6D, 0x80], element([0x62, 0x40], compression))
        }
        let tracks = element([0x16, 0x54, 0xAE, 0x6B], element([0xAE], entry))
        let stored = strippedHeader.map { Data(frame.dropFirst($0.count)) } ?? frame
        let block = Data([0x81, 0x00, 0x00, 0x80]) + stored // track 1, timecode 0, keyframe
        let cluster = element([0x1F, 0x43, 0xB6, 0x75], uint([0xE7], 0) + element([0xA3], block))
        return header + element([0x18, 0x53, 0x80, 0x67], tracks + cluster)
    }
}

extension MatroskaFrameTests {
    private func check(_ data: Data, expecting rgb: (Int, Int, Int)) throws {
        let sandbox = try Sandbox()
        defer { try? FileManager.default.removeItem(at: sandbox.root) }
        let file = sandbox.path("clip.mkv")
        try data.write(to: file)
        let image = try #require(MatroskaFrame.image(at: file))
        #expect(image.width == 320 && image.height == 240)
        // Centre pixel, drawn into a known format.
        var px = [UInt8](repeating: 0, count: 4)
        let ctx = CGContext(data: &px, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(image, in: CGRect(x: -160, y: -120, width: 320, height: 240))
        // Colour management shifts values a little; the strongest channel must still be the right one.
        let expected = [rgb.0, rgb.1, rgb.2], got = px.prefix(3).map(Int.init)
        #expect(got.firstIndex(of: got.max()!) == expected.firstIndex(of: expected.max()!), "got \(px)")
        #expect(got.max()! - got.min()! > 80, "a real picture, not grey: \(px)")
    }

    @Test func decodesH264() throws {
        let f = try EncodedFrame(red: 220, green: 40, blue: 40)
        try check(MKVWriter.file(codecPrivate: f.avcC, frame: f.frame, width: f.width, height: f.height), expecting: (220, 40, 40))
    }

    @Test func decodesHeaderStrippedFrames() throws {
        let f = try EncodedFrame(red: 40, green: 200, blue: 60)
        try check(MKVWriter.file(codecPrivate: f.avcC, frame: f.frame, strippedHeader: f.frame.prefix(2), width: f.width, height: f.height),
                  expecting: (40, 200, 60))
    }

    @Test func decodesSetupCarriedInsideTheFrame() throws {
        let f = try EncodedFrame(red: 30, green: 60, blue: 210)
        try check(MKVWriter.file(codecPrivate: nil, frame: f.annexBWithParameterSets, width: f.width, height: f.height), expecting: (30, 60, 210))
    }

    @Test func notAVideoGivesNil() throws {
        let sandbox = try Sandbox()
        defer { try? FileManager.default.removeItem(at: sandbox.root) }
        #expect(MatroskaFrame.image(at: try sandbox.file("fake.mkv", String(repeating: "x", count: 500))) == nil)
    }
}
