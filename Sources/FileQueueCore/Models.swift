import Foundation

// MARK: - Disks

/// Identifies a physical disk (or, for network volumes, a single volume).
/// Jobs whose disk sets overlap run one after another; disjoint jobs run in parallel.
public struct DiskID: Hashable, Codable, Sendable, Comparable, CustomStringConvertible {
    public let rawValue: String
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public static func < (lhs: DiskID, rhs: DiskID) -> Bool { lhs.rawValue < rhs.rawValue }
    public var description: String { rawValue }
}

public struct DiskInfo: Hashable, Codable, Sendable {
    public var id: DiskID
    /// Human-readable name, e.g. "Macintosh HD".
    public var name: String
    /// Mount point of the volume the job touches, e.g. "/Volumes/USB".
    public var volumePath: String
    public var isCaseSensitive: Bool
    /// The volume can be read but not changed (e.g. NTFS disks, which macOS mounts read-only).
    public var isReadOnly: Bool
    /// File system type, e.g. "apfs", "exfat", "ntfs" (when known).
    public var fileSystem: String?

    public init(id: DiskID, name: String, volumePath: String, isCaseSensitive: Bool = false,
                isReadOnly: Bool = false, fileSystem: String? = nil) {
        self.id = id
        self.name = name
        self.volumePath = volumePath
        self.isCaseSensitive = isCaseSensitive
        self.isReadOnly = isReadOnly
        self.fileSystem = fileSystem
    }

    enum CodingKeys: String, CodingKey { case id, name, volumePath, isCaseSensitive, isReadOnly, fileSystem }

    /// Jobs saved by earlier versions don't have the newer fields.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(DiskID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        volumePath = try c.decode(String.self, forKey: .volumePath)
        isCaseSensitive = try c.decodeIfPresent(Bool.self, forKey: .isCaseSensitive) ?? false
        isReadOnly = try c.decodeIfPresent(Bool.self, forKey: .isReadOnly) ?? false
        fileSystem = try c.decodeIfPresent(String.self, forKey: .fileSystem)
    }
}

// MARK: - Options

public enum ConflictPolicy: String, Codable, Sendable, CaseIterable, Identifiable {
    /// Folders that already exist are merged: identical files are skipped, missing ones copied,
    /// and you're asked about files that differ.
    case merge
    /// Like merge, but same-named files get a quick content check: the same → treated as already there,
    /// different → both kept (the incoming one gets a "name 2" style name). Never asks.
    case mergeKeepBoth
    case ask, skip, replace, keepBoth
    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .merge: "Merge"
        case .mergeKeepBoth: "Merge, Keep Both if Different"
        case .ask: "Ask"
        case .skip: "Skip"
        case .replace: "Replace"
        case .keepBoth: "Keep Both"
        }
    }
}

/// What to do when one item can't be read or written (e.g. a damaged file).
public enum ErrorPolicy: String, Codable, Sendable, CaseIterable, Identifiable {
    case ask, skip, stop
    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .ask: "Ask"
        case .skip: "Skip it and continue"
        case .stop: "Stop the job"
        }
    }
}

public struct JobOptions: Codable, Sendable, Hashable {
    public var conflictPolicy: ConflictPolicy
    /// Ignore the same-disk rule for this job: it neither waits for busy disks nor blocks others.
    public var runInParallelAnyway: Bool
    /// After a cross-disk move, compare SHA-256 checksums before deleting the source.
    public var verifyChecksums: Bool
    public var onError: ErrorPolicy

    public init(conflictPolicy: ConflictPolicy = .merge, runInParallelAnyway: Bool = false,
                verifyChecksums: Bool = false, onError: ErrorPolicy = .ask) {
        self.conflictPolicy = conflictPolicy
        self.runInParallelAnyway = runInParallelAnyway
        self.verifyChecksums = verifyChecksums
        self.onError = onError
    }

    enum CodingKeys: String, CodingKey { case conflictPolicy, runInParallelAnyway, verifyChecksums, onError }

    /// Jobs saved by earlier versions don't have the newer fields.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        conflictPolicy = try c.decodeIfPresent(ConflictPolicy.self, forKey: .conflictPolicy) ?? .merge
        runInParallelAnyway = try c.decodeIfPresent(Bool.self, forKey: .runInParallelAnyway) ?? false
        verifyChecksums = try c.decodeIfPresent(Bool.self, forKey: .verifyChecksums) ?? false
        onError = try c.decodeIfPresent(ErrorPolicy.self, forKey: .onError) ?? .ask
    }
}

// MARK: - Operations

public enum FileOperation: Codable, Sendable, Hashable {
    case copy(sources: [URL], destinationDir: URL)
    case move(sources: [URL], destinationDir: URL)
    case rename(source: URL, newName: String)
    case batchRename(items: [RenamePlanItem])
    case trash(sources: [URL])
    /// Moves (or copies) files into folders; `cleanUpIn`: after a move, remove folders left empty inside it.
    case organize(items: [OrganizeItem], move: Bool, cleanUpIn: URL?)
    /// Reverses the given journal entries (applied newest first).
    case undo(entries: [JournalEntry])

    /// Every location the operation reads or writes, used to work out which disks it touches.
    public var involvedURLs: [URL] {
        switch self {
        case let .copy(sources, dest), let .move(sources, dest):
            return sources + [dest]
        case let .rename(source, _):
            return [source]
        case let .batchRename(items):
            return items.map(\.original)
        case let .trash(sources):
            return sources
        case let .organize(items, _, _):
            let moving = items.filter(\.status.willMove)
            return moving.map(\.source) + moving.map(\.destination)
        case let .undo(entries):
            return entries.flatMap(\.urls)
        }
    }

    /// Files (or folders) the operation reads from.
    public var sourcePaths: [String] {
        switch self {
        case let .copy(sources, _), let .move(sources, _), let .trash(sources): return sources.map(\.standardizedFileURL.path)
        case let .rename(source, _): return [source.standardizedFileURL.path]
        case let .batchRename(items): return items.filter { $0.status == .ok }.map(\.original.standardizedFileURL.path)
        case let .organize(items, _, _): return items.filter(\.status.willMove).map(\.source.standardizedFileURL.path)
        case .undo: return []
        }
    }

    /// Files (or folders) the operation takes away from where they are (moves, renames, trashes).
    public var removedPaths: [String] {
        switch self {
        case .copy, .undo: return []
        case let .organize(_, move, _): return move ? sourcePaths : []
        default: return sourcePaths
        }
    }

    public var verb: String {
        switch self {
        case .copy: "Copy"
        case .move: "Move"
        case .rename: "Rename"
        case .batchRename: "Batch rename"
        case .trash: "Move to Trash"
        case let .organize(_, move, _): move ? "Organize" : "Copy into folders"
        case .undo: "Undo"
        }
    }

    public var defaultTitle: String {
        func items(_ urls: [URL]) -> String {
            urls.count == 1 ? "“\(urls[0].lastPathComponent)”" : "\(urls.count) items"
        }
        switch self {
        case let .copy(sources, dest): return "Copy \(items(sources)) to \(dest.lastPathComponent)"
        case let .move(sources, dest): return "Move \(items(sources)) to \(dest.lastPathComponent)"
        case let .rename(source, newName): return "Rename “\(source.lastPathComponent)” to “\(newName)”"
        case let .batchRename(plan): return "Batch rename \(plan.filter { $0.status == .ok }.count) items"
        case let .trash(sources): return "Move \(items(sources)) to Trash"
        case let .organize(list, move, _):
            let n = list.filter(\.status.willMove).count
            return "\(move ? "Organize" : "Copy into folders") \(n) item\(n == 1 ? "" : "s")"
        case let .undo(entries): return "Undo \(entries.count) step\(entries.count == 1 ? "" : "s")"
        }
    }
}

// MARK: - Rename plan

public enum RenameStatus: Codable, Sendable, Hashable {
    case ok
    case unchanged
    case invalid(String)
    case collidesWithinBatch
    case collidesWithExisting
    /// The file lacks a detail the name needs (e.g. no date taken); it's left as it is.
    case missingMetadata(String)
    /// The name needs this file's details, which haven't been read yet.
    case notRead

    public var isError: Bool {
        switch self {
        case .ok, .unchanged, .missingMetadata, .notRead: false
        default: true
        }
    }

    public var label: String {
        switch self {
        case .ok: "OK"
        case .unchanged: "Unchanged"
        case let .invalid(reason): reason
        case .collidesWithinBatch: "Same name as another file in this batch"
        case .collidesWithExisting: "A file with this name already exists"
        case let .missingMetadata(fields): "Not renamed: no \(fields)"
        case .notRead: "Details not read yet"
        }
    }
}

public struct RenamePlanItem: Codable, Sendable, Hashable, Identifiable {
    public var original: URL
    public var proposedName: String
    public var status: RenameStatus

    public var id: URL { original }
    public var destination: URL {
        original.deletingLastPathComponent().appendingPathComponent(proposedName)
    }

    public init(original: URL, proposedName: String, status: RenameStatus) {
        self.original = original
        self.proposedName = proposedName
        self.status = status
    }
}

// MARK: - Journal

/// Identity of a file at a point in time; undo is skipped when the file changed since.
public struct FileStamp: Codable, Sendable, Hashable {
    public var device: Int64
    public var inode: UInt64
    public var modified: Date

    public func matches(_ other: FileStamp) -> Bool {
        device == other.device && inode == other.inode
            && abs(modified.timeIntervalSince(other.modified)) < 0.01
    }
}

public enum JournalEntry: Codable, Sendable, Hashable {
    case copied(from: URL, to: URL, stamp: FileStamp?)
    case moved(from: URL, to: URL, stamp: FileStamp?)
    case renamed(from: URL, to: URL, stamp: FileStamp?)
    case trashed(original: URL, trashURL: URL, stamp: FileStamp?)
    /// A folder the job created; undo removes it again if it's empty.
    case createdFolder(URL)

    public var urls: [URL] {
        switch self {
        case let .copied(a, b, _), let .moved(a, b, _), let .renamed(a, b, _), let .trashed(a, b, _):
            [a, b]
        case let .createdFolder(url):
            [url]
        }
    }
}

// MARK: - Jobs

public enum JobState: Codable, Sendable, Hashable {
    case pending
    /// Waiting for these disks to be free. Empty means waiting for a free parallel slot.
    case waiting(on: Set<DiskID>)
    case running
    case paused
    /// Not started and held back by the user; does not reserve its disks.
    case onHold
    case completed
    case failed(String)
    case cancelled
    /// Was running when the app quit. Resume restarts it.
    case interrupted

    /// Eligible to be started by the scheduler.
    public var isQueued: Bool {
        switch self {
        case .pending, .waiting: true
        default: false
        }
    }

    /// Running or paused: has an executor task and holds its disks.
    public var isStarted: Bool { self == .running || self == .paused }

    public var isFinished: Bool {
        switch self {
        case .completed, .failed, .cancelled, .interrupted: true
        default: false
        }
    }
}

public struct JobProgress: Codable, Sendable, Hashable {
    public var totalBytes: Int64 = 0
    public var completedBytes: Int64 = 0
    public var totalFiles: Int = 0
    public var completedFiles: Int = 0
    public var currentItem: String?
    public var bytesPerSecond: Double = 0

    public init() {}

    public var fraction: Double {
        if totalBytes > 0 { return min(1, Double(completedBytes) / Double(totalBytes)) }
        if totalFiles > 0 { return min(1, Double(completedFiles) / Double(totalFiles)) }
        return 0
    }

    public var secondsRemaining: Double? {
        guard bytesPerSecond > 1, totalBytes > completedBytes else { return nil }
        return Double(totalBytes - completedBytes) / bytesPerSecond
    }
}

public struct Job: Identifiable, Codable, Sendable, Hashable {
    public let id: UUID
    public var title: String
    public var operation: FileOperation
    public var options: JobOptions
    public var disks: [DiskInfo]
    /// For copies and moves: the disk being written to (older saved jobs may not have it).
    public var destinationDisk: DiskID?
    public var state: JobState
    public var progress: JobProgress
    public var journal: [JournalEntry]
    public var notes: [String]
    /// Items skipped because of an error (optional so older saved jobs still load).
    public var itemErrors: [String]?
    public var problems: [String] { itemErrors ?? [] }
    public var createdAt: Date
    public var finishedAt: Date?
    public var isUndo: Bool
    public var undone: Bool

    public init(
        id: UUID = UUID(), title: String, operation: FileOperation, options: JobOptions,
        disks: [DiskInfo], state: JobState = .pending, isUndo: Bool = false
    ) {
        self.id = id
        self.title = title
        self.operation = operation
        self.options = options
        self.disks = disks
        self.state = state
        self.progress = JobProgress()
        self.journal = []
        self.notes = []
        self.createdAt = Date()
        self.finishedAt = nil
        self.isUndo = isUndo
        self.undone = false
    }

    public var diskIDs: Set<DiskID> { Set(disks.map(\.id)) }

    public func diskName(_ id: DiskID) -> String {
        disks.first { $0.id == id }?.name ?? id.rawValue
    }

    public var canUndo: Bool {
        !isUndo && !undone && !journal.isEmpty && state.isFinished
    }
}

// MARK: - Conflicts

public struct ItemInfo: Sendable, Hashable {
    public var size: Int64?
    public var modified: Date?
    public var isDirectory: Bool

    public init(url: URL) {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isDirectoryKey])
        size = values?.fileSize.map(Int64.init)
        modified = values?.contentModificationDate
        isDirectory = values?.isDirectory ?? false
    }
}

public struct ConflictRequest: Sendable, Identifiable {
    public let id = UUID()
    public let jobID: UUID
    public let jobTitle: String
    public let source: URL
    public let existing: URL
    public let sourceInfo: ItemInfo
    public let existingInfo: ItemInfo
    /// Both are folders, so they can be merged.
    public let canMerge: Bool
}

public enum ConflictResolution: String, Sendable, Codable {
    case skip, replace, keepBoth
    /// Folders only: copy what's missing into the existing folder, skip what's already there.
    case merge
}

public struct ConflictDecision: Sendable {
    public var resolution: ConflictResolution
    public var applyToAll: Bool
    public init(_ resolution: ConflictResolution, applyToAll: Bool = false) {
        self.resolution = resolution
        self.applyToAll = applyToAll
    }
}

public typealias ConflictHandler = @Sendable (ConflictRequest) async -> ConflictDecision

// MARK: - Item errors

/// One item couldn't be copied/moved/trashed. The job waits for a decision.
public struct ItemErrorRequest: Sendable, Identifiable {
    public let id = UUID()
    public let jobID: UUID
    public let jobTitle: String
    public let item: URL
    public let message: String
    /// The disk reported a read/write failure (likely damage), as opposed to e.g. a permission problem.
    public let isDiskError: Bool
}

public enum ItemErrorResolution: String, Sendable, Codable {
    /// Leave this item out and carry on with the rest of the job.
    case skip
    /// End this job; other jobs in the queue continue.
    case stopJob
    /// End this job and put the rest of the queue on hold.
    case stopAll
}

public struct ItemErrorDecision: Sendable {
    public var resolution: ItemErrorResolution
    public var applyToAll: Bool
    public init(_ resolution: ItemErrorResolution, applyToAll: Bool = false) {
        self.resolution = resolution
        self.applyToAll = applyToAll
    }
}

public typealias ItemErrorHandler = @Sendable (ItemErrorRequest) async -> ItemErrorDecision

// MARK: - Errors

public enum FQError: LocalizedError, Equatable {
    case diskUnavailable(String)
    case sourceMissing(String)
    case destinationMissing(String)
    case destinationExists(String)
    case intoItself(String)
    case invalidName(String)
    case planHasErrors
    case verificationFailed(String)
    case posix(Int32, String)
    /// A job would change a disk that can only be read. `hint` suggests what to do instead.
    case readOnly(disk: String, fileSystem: String?, hint: String)
    /// The user chose "Stop All" after an item error.
    case stoppedAll(String)
    /// Some of the new job's files are already in a job still in the queue that will move, rename or
    /// trash them (or the new job would take files that job still needs).
    case overlapsQueuedJob(title: String, count: Int, newJobMoves: Bool)

    /// Errors that make the rest of the job pointless, so there's nothing to skip past.
    public var endsWholeJob: Bool {
        switch self {
        case .destinationMissing, .diskUnavailable, .readOnly, .planHasErrors, .stoppedAll, .overlapsQueuedJob: true
        default: false
        }
    }

    public var errorDescription: String? {
        switch self {
        case let .diskUnavailable(name): "Disk “\(name)” is not available"
        case let .sourceMissing(path): "“\((path as NSString).lastPathComponent)” no longer exists"
        case let .destinationMissing(path): "Destination folder “\((path as NSString).lastPathComponent)” doesn’t exist"
        case let .destinationExists(path): "“\((path as NSString).lastPathComponent)” already exists"
        case let .intoItself(path): "Can’t put “\((path as NSString).lastPathComponent)” inside itself"
        case let .invalidName(reason): reason
        case .planHasErrors: "The rename plan has errors"
        case let .verificationFailed(path): "Copy of “\((path as NSString).lastPathComponent)” didn’t match the original; the original was kept"
        case let .posix(code, path): "\(String(cString: strerror(code))) (\((path as NSString).lastPathComponent))"
        case let .stoppedAll(reason): "Stopped (queue put on hold): \(reason)"
        case let .overlapsQueuedJob(title, count, newJobMoves):
            newJobMoves
                ? "\(count.formatted()) of these files are still needed by “\(title)”, which is in the queue. Moving them now would make that job fail. Wait for it to finish, or remove it from the queue."
                : "\(count.formatted()) of these files are already in “\(title)”, which is in the queue and will move them first — so this job wouldn’t find them. Wait for it to finish, or remove it from the queue."
        case let .readOnly(disk, fileSystem, hint):
            "“\(disk)” is read-only" + (fileSystem?.lowercased() == "ntfs" ? " (macOS can read NTFS disks but not change them)" : "") + ". \(hint)"
        }
    }
}
