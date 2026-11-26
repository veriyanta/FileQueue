import Foundation
@testable import FileQueueCore

/// Maps "/HD/…", "/USB-A/…" etc. to a fake disk named after the first path component.
struct FakeDiskResolver: DiskResolving {
    func disk(for url: URL) throws -> DiskInfo {
        let name = url.pathComponents.dropFirst().first ?? "root"
        if name == "Ejected" { throw FQError.diskUnavailable(name) }
        return DiskInfo(id: DiskID(name), name: name, volumePath: "/\(name)")
    }
}

/// An executor whose jobs block until the test releases them by title.
final class GatedExecutor: JobExecuting, @unchecked Sendable {
    private let lock = NSLock()
    private var released: Set<String> = []
    private var _started: [String] = []

    var started: [String] { lock.withLock { _started } }

    func release(_ titles: String...) {
        lock.withLock { titles.forEach { released.insert($0) } }
    }

    func execute(job: Job, context: ExecutionContext) async throws {
        lock.withLock { _started.append(job.title) }
        while !lock.withLock({ released.contains(job.title) }) {
            try await context.control.checkpoint()
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}

final class MemoryStore: QueueStore, @unchecked Sendable {
    private let lock = NSLock()
    private var saved: [Job] = []
    init(_ jobs: [Job] = []) { saved = jobs }
    func load() throws -> [Job] { lock.withLock { saved } }
    func save(_ jobs: [Job]) throws { lock.withLock { saved = jobs } }
}

/// Polls until `condition` holds (or fails after a timeout).
func eventually(
    _ engine: QueueEngine, timeout: Duration = .seconds(5),
    _ condition: @escaping ([Job]) -> Bool
) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if condition(await engine.jobs) { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return false
}

extension Array where Element == Job {
    func state(_ title: String) -> JobState? { first { $0.title == title }?.state }
    func id(_ title: String) -> UUID { first { $0.title == title }!.id }
}

func url(_ path: String) -> URL { URL(fileURLWithPath: path) }

/// A fresh temporary folder, removed by the caller with `cleanup()`.
struct Sandbox {
    let root: URL
    let trash: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("FileQueueTests-\(UUID().uuidString)")
            .resolvingSymlinksInPath()
        trash = root.appendingPathComponent("_Trash")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    @discardableResult
    func file(_ path: String, _ contents: String = "hello") throws -> URL {
        let u = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: u)
        return u
    }

    @discardableResult
    func dir(_ path: String) throws -> URL {
        let u = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    func path(_ p: String) -> URL { root.appendingPathComponent(p) }
    func exists(_ p: String) -> Bool { FS.itemExists(path(p)) }
    func read(_ p: String) -> String? { try? String(contentsOf: path(p), encoding: .utf8) }
    func names(_ p: String = "") -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: path(p).path)) ?? []).filter { $0 != "_Trash" }.sorted()
    }

    func engine(
        policy: ConflictHandler? = nil, maxConcurrent: Int = 4, store: (any QueueStore)? = nil
    ) async -> QueueEngine {
        let resolver = SystemDiskResolver()
        let executor = FileOperationExecutor(diskResolver: resolver, trasher: FolderTrash(folder: trash))
        let engine = QueueEngine(executor: executor, diskResolver: resolver, store: store, maxConcurrent: maxConcurrent)
        await engine.setConflictHandler(policy)
        return engine
    }

    func cleanup() { try? FileManager.default.removeItem(at: root) }
}

/// A small disk image attached for the duration of a test (skipped if hdiutil isn't usable).
final class DiskImage {
    let mountPoint: URL
    private let imageURL: URL
    var imagePath: String { imageURL.path }

    init?(caseSensitive: Bool, sizeMB: Int = 64, fileSystem: String? = nil) {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("fq-dmg-\(UUID().uuidString)")
        imageURL = base.appendingPathExtension("dmg")
        mountPoint = base.appendingPathExtension("mnt").resolvingSymlinksInPath()
        let fs = fileSystem ?? (caseSensitive ? "Case-sensitive APFS" : "APFS")
        guard Self.run(["create", "-quiet", "-size", "\(sizeMB)m", "-fs", fs, "-volname", "FQTEST", imageURL.path]),
              (try? FileManager.default.createDirectory(at: mountPoint, withIntermediateDirectories: true)) != nil,
              Self.run(["attach", "-quiet", "-nobrowse", "-mountpoint", mountPoint.path, imageURL.path])
        else {
            try? FileManager.default.removeItem(at: imageURL)
            return nil
        }
    }

    func detach() {
        _ = Self.run(["detach", "-quiet", "-force", mountPoint.path])
        try? FileManager.default.removeItem(at: imageURL)
        try? FileManager.default.removeItem(at: mountPoint)
    }

    static func runDiskutil(_ args: [String]) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }

    static func run(_ args: [String]) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }
}
