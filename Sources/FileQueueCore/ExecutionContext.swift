import Foundation

/// Thread-safe pause/cancel flags shared between the queue and a running executor.
public final class JobControl: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var paused = false

    public init() {}

    public var isCancelled: Bool { lock.withLock { cancelled } }
    public var isPaused: Bool { lock.withLock { paused } }

    public func cancel() { lock.withLock { cancelled = true } }
    public func pause() { lock.withLock { paused = true } }
    public func resume() { lock.withLock { paused = false } }

    /// Call between items. Throws if cancelled; suspends while paused.
    public func checkpoint() async throws {
        while true {
            let (c, p) = lock.withLock { (cancelled, paused) }
            if c { throw CancellationError() }
            if !p { return }
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    /// Blocking variant for use inside synchronous callbacks (e.g. copyfile).
    /// Returns `false` if the job was cancelled.
    public func blockingCheckpoint() -> Bool {
        while true {
            let (c, p) = lock.withLock { (cancelled, paused) }
            if c { return false }
            if !p { return true }
            usleep(100_000)
        }
    }
}

/// Collects progress and forwards it at most ~10 times per second.
public final class ProgressReporter: @unchecked Sendable {
    private let lock = NSLock()
    private var progress = JobProgress()
    private var lastEmit: Date = .distantPast
    private var lastEmitBytes: Int64 = 0
    private let interval: TimeInterval
    private let sink: @Sendable (JobProgress) -> Void

    public init(interval: TimeInterval = 0.1, sink: @escaping @Sendable (JobProgress) -> Void) {
        self.interval = interval
        self.sink = sink
    }

    public var current: JobProgress { lock.withLock { progress } }

    public func update(_ body: (inout JobProgress) -> Void) {
        let toSend: JobProgress? = lock.withLock {
            body(&progress)
            let now = Date()
            let elapsed = now.timeIntervalSince(lastEmit)
            guard elapsed >= interval else { return nil }
            if lastEmit != .distantPast, elapsed > 0 {
                let instant = Double(progress.completedBytes - lastEmitBytes) / elapsed
                progress.bytesPerSecond = progress.bytesPerSecond == 0
                    ? instant : progress.bytesPerSecond * 0.7 + instant * 0.3
            }
            lastEmit = now
            lastEmitBytes = progress.completedBytes
            return progress
        }
        if let toSend { sink(toSend) }
    }

    /// Sends the latest values immediately.
    public func flush() {
        sink(current)
    }
}

/// Records completed steps so they can be undone, plus notes for the user.
public final class JournalRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _entries: [JournalEntry] = []
    private var _notes: [String] = []
    private var _problems: [String] = []

    public init() {}

    public var entries: [JournalEntry] { lock.withLock { _entries } }
    public var notes: [String] { lock.withLock { _notes } }
    public var problems: [String] { lock.withLock { _problems } }
    public func problem(_ text: String) { lock.withLock { _problems.append(text) } }

    public func record(_ entry: JournalEntry) { lock.withLock { _entries.append(entry) } }
    public func note(_ text: String) { lock.withLock { _notes.append(text) } }
}

public struct ExecutionContext: Sendable {
    public let jobID: UUID
    public let jobTitle: String
    public let control: JobControl
    public let progress: ProgressReporter
    public let journal: JournalRecorder
    public let resolveConflict: ConflictHandler
    public let resolveItemError: ItemErrorHandler

    public init(
        jobID: UUID, jobTitle: String, control: JobControl, progress: ProgressReporter,
        journal: JournalRecorder, resolveConflict: @escaping ConflictHandler,
        resolveItemError: @escaping ItemErrorHandler = { _ in ItemErrorDecision(.stopJob) }
    ) {
        self.jobID = jobID
        self.jobTitle = jobTitle
        self.control = control
        self.progress = progress
        self.journal = journal
        self.resolveConflict = resolveConflict
        self.resolveItemError = resolveItemError
    }
}

public protocol JobExecuting: Sendable {
    func execute(job: Job, context: ExecutionContext) async throws
}

/// Runs blocking file-system work off the Swift concurrency thread pool.
func runBlocking<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in
        DispatchQueue.global(qos: .userInitiated).async {
            continuation.resume(with: Result { try work() })
        }
    }
}
