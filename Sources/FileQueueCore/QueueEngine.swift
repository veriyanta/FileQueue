import Foundation

/// Owns the job list and starts jobs according to `Scheduler`.
public actor QueueEngine {
    public private(set) var jobs: [Job]
    public private(set) var maxConcurrent: Int

    private let executor: any JobExecuting
    private let diskResolver: any DiskResolving
    private let store: (any QueueStore)?
    private var controls: [UUID: JobControl] = [:]
    private var subscribers: [UUID: AsyncStream<[Job]>.Continuation] = [:]
    private var conflictHandler: ConflictHandler?
    private var itemErrorHandler: ItemErrorHandler?

    public init(
        executor: (any JobExecuting)? = nil,
        diskResolver: any DiskResolving = SystemDiskResolver(),
        store: (any QueueStore)? = nil,
        maxConcurrent: Int = 4
    ) {
        self.diskResolver = diskResolver
        self.executor = executor ?? FileOperationExecutor(diskResolver: diskResolver)
        self.store = store
        self.maxConcurrent = max(1, maxConcurrent)
        self.jobs = Self.restore((try? store?.load()) ?? [])
    }

    /// After a relaunch nothing starts by itself: running jobs become `interrupted`
    /// and queued ones go on hold until the user resumes them.
    static func restore(_ saved: [Job]) -> [Job] {
        saved.map { job in
            var job = job
            switch job.state {
            case .running, .paused: job.state = .interrupted
            case .pending, .waiting: job.state = .onHold
            default: break
            }
            return job
        }
    }

    // MARK: Observation

    public func updates() -> AsyncStream<[Job]> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<[Job]>.makeStream(bufferingPolicy: .bufferingNewest(1))
        subscribers[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeSubscriber(id) }
        }
        continuation.yield(jobs)
        return stream
    }

    private func removeSubscriber(_ id: UUID) { subscribers[id] = nil }

    public func setConflictHandler(_ handler: ConflictHandler?) {
        conflictHandler = handler
    }

    /// Asked when one item fails and the job's error policy is "ask". Without one, the job stops.
    public func setItemErrorHandler(_ handler: ItemErrorHandler?) {
        itemErrorHandler = handler
    }

    public func job(_ id: UUID) -> Job? { jobs.first { $0.id == id } }

    // MARK: Adding jobs

    @discardableResult
    public func enqueue(_ operation: FileOperation, options: JobOptions = JobOptions(), title: String? = nil,
                        allowOverlap: Bool = false) throws -> UUID {
        try checkWritable(operation)
        if !allowOverlap { try checkOverlap(operation) }
        let disks = try resolveDisks(for: operation, lenient: false)
        var job = Job(title: title ?? operation.defaultTitle, operation: operation, options: options, disks: disks)
        job.destinationDisk = destinationDisk(of: operation)
        jobs.append(job)
        changed()
        return job.id
    }

    /// Refuses a job that would trip over a job still in the queue: it reads files that job will move,
    /// rename or trash away — or it would take away files that job still needs. (Two organize jobs on
    /// overlapping folders, e.g. "jpg" and "jpg/Group 1", would otherwise leave the second finding nothing.)
    func checkOverlap(_ operation: FileOperation) throws {
        let newReads = operation.sourcePaths
        let newRemoves = Set(operation.removedPaths)
        guard !newReads.isEmpty else { return }
        // Only folders can have another job's files inside them; files are checked by path alone.
        let folders = Set(newReads.filter { FS.isDirectory(URL(fileURLWithPath: $0)) })
        for job in jobs where job.state.isQueued || job.state.isStarted || job.state == .onHold {
            let theirRemoves = Self.PathSet(job.operation.removedPaths)
            let theirReads = Self.PathSet(job.operation.sourcePaths)
            // They'll take away what we want to read.
            let lost = newReads.filter { theirRemoves.containsOrInside($0) || (folders.contains($0) && theirRemoves.hasInside($0)) }.count
            if lost > 0 { throw FQError.overlapsQueuedJob(title: job.title, count: lost, newJobMoves: false) }
            // We'd take away what they still need to read.
            let taken = newRemoves.filter { theirReads.containsOrInside($0) || (folders.contains($0) && theirReads.hasInside($0)) }.count
            if taken > 0 { throw FQError.overlapsQueuedJob(title: job.title, count: taken, newJobMoves: true) }
        }
    }

    /// Paths with quick "is this path (or a folder above it) in the set" checks.
    struct PathSet {
        let paths: Set<String>
        init(_ list: [String]) { paths = Set(list) }

        /// `path` itself is in the set, or is inside a folder that is.
        func containsOrInside(_ path: String) -> Bool {
            guard !paths.isEmpty else { return false }
            var p = path
            while true {
                if paths.contains(p) { return true }
                guard let slash = p.lastIndex(of: "/"), slash != p.startIndex else { return false }
                p = String(p[..<slash])
            }
        }

        /// Something in the set is inside the folder `path`.
        func hasInside(_ path: String) -> Bool {
            let prefix = path.hasSuffix("/") ? path : path + "/"
            return paths.contains { $0.hasPrefix(prefix) }
        }
    }

    /// Queues a job that reverses `id`. Undo jobs follow the same disk rules.
    @discardableResult
    public func undo(_ id: UUID) throws -> UUID? {
        guard let i = index(id), jobs[i].canUndo else { return nil }
        let operation = FileOperation.undo(entries: jobs[i].journal)
        let disks = try resolveDisks(for: operation, lenient: true)
        let undoJob = Job(
            title: "Undo: \(jobs[i].title)", operation: operation,
            options: JobOptions(conflictPolicy: .skip), disks: disks, isUndo: true
        )
        jobs[i].undone = true
        jobs.append(undoJob)
        changed()
        return undoJob.id
    }

    /// Undoes the most recently finished job that can be undone.
    @discardableResult
    public func undoLast() throws -> UUID? {
        let candidate = jobs.filter(\.canUndo).max { ($0.finishedAt ?? .distantPast) < ($1.finishedAt ?? .distantPast) }
        guard let candidate else { return nil }
        return try undo(candidate.id)
    }

    /// Refuses, before anything is copied, a job that would have to change a read-only disk.
    /// (Without this, a move off an NTFS disk would copy everything and only fail when deleting the originals.)
    func checkWritable(_ operation: FileOperation) throws {
        // Files in the same folder are on the same disk: check each folder once.
        var checked = Set<String>()
        func check(_ url: URL, hint: String) throws {
            let folder = Self.folderKey(url)
            guard checked.insert(folder.path).inserted else { return }
            let disk = try diskResolver.disk(for: folder)
            if disk.isReadOnly && FS.isOnReadOnlyFileSystem(folder) {
                throw FQError.readOnly(disk: disk.name, fileSystem: disk.fileSystem, hint: hint)
            }
        }
        switch operation {
        case let .copy(_, dest):
            try check(dest, hint: "Choose a destination on another disk.")
        case let .move(sources, dest):
            try check(dest, hint: "Choose a destination on another disk.")
            for source in sources {
                try check(source, hint: "Files can’t be removed from it, so they can’t be moved. Use Copy instead.")
            }
        case let .rename(source, _):
            try check(source, hint: "Items on it can’t be renamed.")
        case let .batchRename(items):
            for item in items { try check(item.original, hint: "Items on it can’t be renamed.") }
        case let .trash(sources):
            for source in sources { try check(source, hint: "Items on it can’t be moved to the Trash.") }
        case let .organize(items, move, _):
            for item in items where item.status.willMove {
                try check(item.destination, hint: "Choose a destination on another disk.")
                if move { try check(item.source, hint: "Files can’t be moved off it. Use Copy instead.") }
            }
        case .undo:
            break
        }
    }

    private func destinationDisk(of operation: FileOperation) -> DiskID? {
        switch operation {
        case let .copy(_, dest), let .move(_, dest): return try? diskResolver.disk(for: dest).id
        default: return nil
        }
    }

    /// The folder that decides a URL's disk: the item itself if it's a folder (it may be a disk of its own),
    /// otherwise the folder it's in. Lets thousands of files in a few folders be looked up a few times.
    static func folderKey(_ url: URL) -> URL {
        FS.isDirectory(url) ? url.standardizedFileURL : url.deletingLastPathComponent().standardizedFileURL
    }

    private func resolveDisks(for operation: FileOperation, lenient: Bool) throws -> [DiskInfo] {
        var result: [DiskInfo] = []
        var seen = Set<String>()
        for url in operation.involvedURLs {
            let folder = Self.folderKey(url)
            guard seen.insert(folder.path).inserted else { continue }
            let disk: DiskInfo
            do {
                disk = try diskResolver.disk(for: folder)
            } catch {
                if lenient { continue }
                throw error
            }
            if !result.contains(where: { $0.id == disk.id }) { result.append(disk) }
        }
        return result
    }

    // MARK: Controls

    public func pause(_ id: UUID) {
        guard let i = index(id) else { return }
        switch jobs[i].state {
        case .running:
            controls[id]?.pause()
            jobs[i].state = .paused // keeps holding its disks
        case .pending, .waiting:
            jobs[i].state = .onHold // releases its place in the disk lanes
        default: return
        }
        changed()
    }

    public func resume(_ id: UUID) {
        guard let i = index(id) else { return }
        switch jobs[i].state {
        case .paused:
            controls[id]?.resume()
            jobs[i].state = .running
        case .onHold:
            refreshDisks(i)
            jobs[i].state = .pending
        case .interrupted:
            refreshDisks(i)
            jobs[i].progress = JobProgress()
            jobs[i].state = .pending
        default: return
        }
        changed()
    }

    public func cancel(_ id: UUID) {
        guard let i = index(id) else { return }
        switch jobs[i].state {
        case .running, .paused:
            controls[id]?.cancel() // the task finishes and frees the disks
        case .pending, .waiting, .onHold, .interrupted:
            jobs[i].state = .cancelled
            jobs[i].finishedAt = Date()
            changed()
        default: break
        }
    }

    public func retry(_ id: UUID) {
        guard let i = index(id) else { return }
        switch jobs[i].state {
        case .completed where jobs[i].problems.isEmpty:
            break
        case .failed, .cancelled, .interrupted, .completed:
            // A job that finished with skipped items can be retried too: with Merge it only fetches what's missing.
            refreshDisks(i)
            jobs[i].itemErrors = nil
            jobs[i].progress = JobProgress()
            jobs[i].finishedAt = nil
            jobs[i].state = .pending
            changed()
        default: break
        }
    }

    public func remove(_ id: UUID) {
        guard let i = index(id), !jobs[i].state.isStarted else { return }
        jobs.remove(at: i)
        changed()
    }

    /// Moves a not-yet-started job up (`offset < 0`) or down among the other waiting jobs.
    /// Order decides who goes first on a shared disk.
    public func move(_ id: UUID, by offset: Int) {
        guard offset != 0, let i = index(id), isReorderable(jobs[i].state) else { return }
        var target = i
        var remaining = abs(offset)
        var cursor = i
        while remaining > 0 {
            cursor += offset < 0 ? -1 : 1
            guard jobs.indices.contains(cursor) else { break }
            if isReorderable(jobs[cursor].state) {
                target = cursor
                remaining -= 1
            }
        }
        guard target != i else { return }
        let job = jobs.remove(at: i)
        jobs.insert(job, at: target)
        changed()
    }

    private func isReorderable(_ state: JobState) -> Bool { state.isQueued || state == .onHold }

    /// "Stop All": pause running jobs and put waiting ones on hold, until the user resumes them.
    private func holdQueue(except id: UUID) {
        for i in jobs.indices where jobs[i].id != id {
            switch jobs[i].state {
            case .running:
                controls[jobs[i].id]?.pause()
                jobs[i].state = .paused
            case .pending, .waiting:
                jobs[i].state = .onHold
            default: break
            }
        }
    }

    public func pauseAll() {
        for job in jobs where job.state == .running || job.state.isQueued { pause(job.id) }
    }

    public func resumeAll() {
        for job in jobs where job.state == .paused || job.state == .onHold { resume(job.id) }
    }

    public func clearFinished() {
        jobs.removeAll { $0.state == .completed || $0.state == .cancelled }
        changed()
    }

    public func setMaxConcurrent(_ value: Int) {
        maxConcurrent = min(8, max(1, value))
        changed()
    }

    /// Called when a volume is ejected: jobs that haven't started yet on it fail with a clear reason.
    /// Running jobs fail on their own when their next file operation errors.
    public func handleUnmount(volumePath: String) {
        var didChange = false
        for i in jobs.indices where jobs[i].state.isQueued || jobs[i].state == .onHold {
            if let disk = jobs[i].disks.first(where: { $0.volumePath == volumePath }) {
                jobs[i].state = .failed(FQError.diskUnavailable(disk.name).localizedDescription)
                jobs[i].finishedAt = Date()
                didChange = true
            }
        }
        if didChange { changed() }
    }

    private func refreshDisks(_ i: Int) {
        if let disks = try? resolveDisks(for: jobs[i].operation, lenient: jobs[i].isUndo), !disks.isEmpty {
            jobs[i].disks = disks
            jobs[i].destinationDisk = destinationDisk(of: jobs[i].operation)
        }
    }

    // MARK: Scheduling

    private func changed() {
        schedule()
        persist()
        emit()
    }

    private func schedule() {
        let decision = Scheduler.decide(jobs: jobs, maxConcurrent: maxConcurrent)
        for (id, blockers) in decision.waiting {
            if let i = index(id) { jobs[i].state = .waiting(on: blockers) }
        }
        for id in decision.toStart { start(id) }
    }

    private func start(_ id: UUID) {
        guard let i = index(id) else { return }
        jobs[i].state = .running
        let job = jobs[i]
        let control = JobControl()
        controls[id] = control

        let reporter = ProgressReporter { [weak self] progress in
            Task { await self?.receiveProgress(id, progress) }
        }
        let handler = conflictHandler
        let errorHandler = itemErrorHandler
        let context = ExecutionContext(
            jobID: id, jobTitle: job.title, control: control, progress: reporter,
            journal: JournalRecorder(),
            resolveConflict: { request in
                guard let handler else { return ConflictDecision(.skip) }
                return await handler(request)
            },
            resolveItemError: { request in
                guard let errorHandler else { return ItemErrorDecision(.stopJob) }
                return await errorHandler(request)
            }
        )
        let executor = self.executor
        Task.detached { [weak self] in
            var failure: Error?
            do {
                try await executor.execute(job: job, context: context)
            } catch {
                failure = error
            }
            await self?.finish(id, failure: failure, context: context)
        }
    }

    private func receiveProgress(_ id: UUID, _ progress: JobProgress) {
        guard let i = index(id), jobs[i].state.isStarted else { return }
        jobs[i].progress = progress
        emit()
    }

    private func finish(_ id: UUID, failure: Error?, context: ExecutionContext) {
        controls[id] = nil
        guard let i = index(id) else { return }
        jobs[i].journal += context.journal.entries
        jobs[i].notes += context.journal.notes
        let problems = context.journal.problems
        jobs[i].itemErrors = problems.isEmpty ? nil : problems
        var progress = context.progress.current
        progress.bytesPerSecond = 0
        progress.currentItem = nil
        jobs[i].progress = progress
        jobs[i].finishedAt = Date()

        if context.control.isCancelled || failure is CancellationError {
            jobs[i].state = .cancelled
        } else if case .stoppedAll? = failure as? FQError {
            jobs[i].state = .failed(failure!.localizedDescription)
            holdQueue(except: id)
        } else if let failure {
            jobs[i].state = .failed(failure.localizedDescription)
        } else {
            jobs[i].state = .completed
        }
        changed()
    }

    private func persist() {
        try? store?.save(jobs)
    }

    private func emit() {
        for continuation in subscribers.values { continuation.yield(jobs) }
    }

    private func index(_ id: UUID) -> Int? { jobs.firstIndex { $0.id == id } }

    // MARK: Testing support

    /// Waits until no job is queued, running or paused.
    public func waitUntilIdle(timeout: Duration = .seconds(30)) async {
        let deadline = ContinuousClock.now + timeout
        while jobs.contains(where: { $0.state.isQueued || $0.state.isStarted }), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }
}
