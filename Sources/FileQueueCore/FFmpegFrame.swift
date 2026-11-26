import CoreGraphics
import Foundation
import ImageIO

/// Optional last resort for video previews: if ffmpeg is installed (e.g. `brew install ffmpeg`), it can decode
/// what macOS can't (XviD ASP, CineForm, DivX 3, WMV, FLV, RealMedia…). Nothing is bundled or downloaded.
public enum FFmpegFrame {
    /// Where ffmpeg is usually installed (Homebrew on Apple silicon / Intel, MacPorts).
    static let candidates = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/opt/local/bin/ffmpeg"]

    /// The ffmpeg to use, or nil if none is installed. Checked again each time, so installing it while the app runs works.
    public static var executable: URL? {
        if let custom = ProcessInfo.processInfo.environment["FILEQUEUE_FFMPEG"], FileManager.default.isExecutableFile(atPath: custom) {
            return URL(fileURLWithPath: custom)
        }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }.map(URL.init(fileURLWithPath:))
    }

    /// At most a few ffmpeg processes at once, so a folder full of videos doesn't swamp the Mac.
    private static let limiter = Limiter(slots: 3)

    /// A frame about `position` (0…1) into the video, at most `maxSide` pixels wide or tall.
    public static func image(at url: URL, duration: Double?, maxSide: Int, position: Double = 0.1,
                             executable: URL? = FFmpegFrame.executable, timeout: TimeInterval = 20) async -> CGImage? {
        guard let executable else { return nil }
        await limiter.acquire()
        defer { Task { await limiter.release() } }
        // Seek a little way in (the first frame is often black); if that fails, try the very start.
        var offsets = [0.0]
        if let duration, duration > 2 { offsets.insert(duration * position, at: 0) } else { offsets.insert(5, at: 0) }
        for seconds in offsets {
            if let image = run(executable, url: url, seconds: seconds, maxSide: maxSide, timeout: timeout) { return image }
        }
        return nil
    }

    static func arguments(for url: URL, seconds: Double, maxSide: Int) -> [String] {
        ["-nostdin", "-hide_banner", "-loglevel", "error",
         "-ss", String(format: "%.2f", seconds), "-i", url.path,
         "-frames:v", "1", "-an", "-sn",
         "-vf", "scale=w=\(maxSide):h=\(maxSide):force_original_aspect_ratio=decrease",
         "-f", "image2pipe", "-c:v", "png", "-"]
    }

    static func run(_ executable: URL, url: URL, seconds: Double, maxSide: Int, timeout: TimeInterval) -> CGImage? {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments(for: url, seconds: seconds, maxSide: maxSide)
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return nil }

        // Stop it if it hangs (e.g. a damaged file).
        let killer = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        killer.cancel()

        guard process.terminationStatus == 0, !data.isEmpty,
              let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }
}

/// A simple async semaphore.
actor Limiter {
    private var free: Int
    private var waiting: [CheckedContinuation<Void, Never>] = []

    init(slots: Int) { free = slots }

    func acquire() async {
        if free > 0 {
            free -= 1
            return
        }
        await withCheckedContinuation { waiting.append($0) }
    }

    func release() {
        if waiting.isEmpty { free += 1 } else { waiting.removeFirst().resume() }
    }
}
