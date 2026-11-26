import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import FileQueueCore

/// Uses a stand-in "ffmpeg" shell script, so these run whether or not ffmpeg is installed.
@Suite struct FFmpegFrameTests {
    /// A small PNG, and a fake ffmpeg whose behaviour is `body` (with $PNG and $LOG set).
    func fake(_ body: String, in sandbox: Sandbox) throws -> (URL, URL) {
        let png = sandbox.path("frame.png")
        let ctx = CGContext(data: nil, width: 8, height: 6, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: 8, height: 6))
        let dest = CGImageDestinationCreateWithURL(png as CFURL, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        CGImageDestinationFinalize(dest)
        let log = sandbox.path("args.log")
        let script = try sandbox.file("ffmpeg", "#!/bin/sh\nPNG='\(png.path)'\nLOG='\(log.path)'\necho \"$*\" >> \"$LOG\"\n\(body)\n")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return (script, log)
    }

    @Test func readsTheFrameFfmpegWrites() async throws {
        let sandbox = try Sandbox()
        defer { try? FileManager.default.removeItem(at: sandbox.root) }
        let (ffmpeg, log) = try fake(#"cat "$PNG""#, in: sandbox)
        let video = try sandbox.file("movie.avi")
        let image = await FFmpegFrame.image(at: video, duration: 600, maxSide: 256, executable: ffmpeg)
        #expect(image?.width == 8 && image?.height == 6)
        let args = try String(contentsOf: log, encoding: .utf8)
        #expect(args.contains("-ss 60.00"))  // 10% in
        #expect(args.contains(video.path))
        #expect(args.contains("scale=w=256:h=256"))
    }

    @Test func triesTheStartWhenSeekingFails() async throws {
        let sandbox = try Sandbox()
        defer { try? FileManager.default.removeItem(at: sandbox.root) }
        let (ffmpeg, log) = try fake(#"case "$*" in *"-ss 0.00 "*) cat "$PNG";; *) exit 1;; esac"#, in: sandbox)
        let image = await FFmpegFrame.image(at: try sandbox.file("clip.flv"), duration: nil, maxSide: 128, executable: ffmpeg)
        #expect(image != nil)
        #expect(try String(contentsOf: log, encoding: .utf8).split(separator: "\n").count == 2)
    }

    @Test func givesUpOnAHungProcess() async throws {
        let sandbox = try Sandbox()
        defer { try? FileManager.default.removeItem(at: sandbox.root) }
        let (ffmpeg, _) = try fake("exec sleep 30", in: sandbox)
        let start = Date()
        let image = await FFmpegFrame.image(at: try sandbox.file("bad.avi"), duration: 100, maxSide: 128, executable: ffmpeg, timeout: 0.5)
        #expect(image == nil)
        #expect(Date().timeIntervalSince(start) < 5)
    }

    @Test func nothingWithoutFfmpeg() async throws {
        let sandbox = try Sandbox()
        defer { try? FileManager.default.removeItem(at: sandbox.root) }
        #expect(await FFmpegFrame.image(at: try sandbox.file("x.avi"), duration: 10, maxSide: 64, executable: nil) == nil)
    }

    /// With a real ffmpeg installed: formats macOS can't preview (made by ffmpeg itself) still get a frame.
    @Test func realFfmpegDecodesWhatMacOSCant() async throws {
        guard let ffmpeg = FFmpegFrame.executable else { return }
        let sandbox = try Sandbox()
        defer { try? FileManager.default.removeItem(at: sandbox.root) }
        let samples: [(String, [String])] = [
            ("cineform.avi", ["-c:v", "cfhd", "-pix_fmt", "yuv422p10le"]),
            ("xvid-asp.avi", ["-c:v", "mpeg4", "-vtag", "XVID", "-bf", "2", "-flags", "+qpel"]),
            ("divx3.avi", ["-c:v", "msmpeg4", "-vtag", "DIV3"]),
            ("clip.wmv", ["-c:v", "wmv2"]),
            ("clip.flv", ["-c:v", "flv1"]),
        ]
        for (name, codec) in samples {
            let out = sandbox.path(name)
            let make = Process()
            make.executableURL = ffmpeg
            make.arguments = ["-nostdin", "-loglevel", "error", "-f", "lavfi", "-i", "testsrc=size=320x240:rate=25:duration=4"] + codec + [out.path]
            try make.run()
            make.waitUntilExit()
            #expect(make.terminationStatus == 0, "making \(name)")
            let start = Date()
            let image = await FFmpegFrame.image(at: out, duration: 4, maxSide: 128)
            #expect(image != nil, "\(name)")
            if let image { #expect(max(image.width, image.height) == 128, "\(name) size") }
            print("ffmpeg frame for \(name): \(image.map { "\($0.width)x\($0.height)" } ?? "none") in \(String(format: "%.2f", Date().timeIntervalSince(start)))s")
        }
    }
}
