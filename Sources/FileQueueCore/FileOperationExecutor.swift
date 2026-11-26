import Foundation

/// Performs the real file operations for a job.
///
/// Safety rules: nothing is ever deleted permanently except the source of a cross-disk move,
/// and only after its copy has been verified. Replaced items go to the Trash.
public struct FileOperationExecutor: JobExecuting {
    let diskResolver: any DiskResolving
    let trasher: any Trashing

    public init(diskResolver: any DiskResolving = SystemDiskResolver(), trasher: any Trashing = SystemTrash()) {
        self.diskResolver = diskResolver
        self.trasher = trasher
    }

    public func execute(job: Job, context: ExecutionContext) async throws {
        switch job.operation {
        case let .copy(sources, dest):
            try await transfer(sources, to: dest, move: false, job: job, context: context)
        case let .move(sources, dest):
            try await transfer(sources, to: dest, move: true, job: job, context: context)
        case let .rename(source, newName):
            try await rename(source, to: newName, job: job, context: context)
        case let .batchRename(items):
            try await batchRename(items, context: context)
        case let .trash(sources):
            try await trash(sources, job: job, context: context)
        case let .organize(items, move, cleanUpIn):
            try await organize(items, move: move, cleanUpIn: cleanUpIn, job: job, context: context)
        case let .undo(entries):
            try await undo(entries, context: context)
        }
    }

    // MARK: Copy & move

    /// Running totals for the progress bar while items are copied, merged or skipped.
    private final class Tally: @unchecked Sendable {
        var bytes: Int64 = 0
        var files = 0
        func add(_ size: (bytes: Int64, files: Int), _ context: ExecutionContext) {
            bytes += size.bytes
            files += size.files
            let (b, f) = (bytes, files)
            context.progress.update { $0.completedBytes = b; $0.completedFiles = f }
        }
    }

    /// "Apply to all" answers, kept separately for folders and for files.
    private struct Sticky {
        var folder: ConflictResolution?
        var file: ConflictResolution?
    }

    /// The "do the same for other errors in this job" answer.
    private final class ErrorChoice: @unchecked Sendable {
        var applied: ItemErrorResolution?
    }

    /// What a merge did, for the job's notes.
    private final class MergeStats {
        var alreadyThere = 0
        var copied = 0
        var skippedDifferent = 0
        var keptBoth = 0
    }

    /// Runs the work for one item. If it fails with an item-level error (a damaged file, an unreadable
    /// folder, a permission problem…), the job's error policy — or the user — decides whether to skip
    /// it and carry on, stop this job, or stop everything. Returns false if the item was skipped.
    @discardableResult
    private func attempt(_ item: URL, verb: String, job: Job, context: ExecutionContext, errors: ErrorChoice,
                         _ work: () async throws -> Void) async throws -> Bool {
        do {
            try await work()
            return true
        } catch {
            if error is CancellationError || context.control.isCancelled { throw CancellationError() }
            if let fq = error as? FQError, fq.endsWholeJob { throw error }
            let message = FS.describe(error)
            let resolution: ItemErrorResolution
            if let applied = errors.applied {
                resolution = applied
            } else {
                switch job.options.onError {
                case .skip: resolution = .skip
                case .stop: resolution = .stopJob
                case .ask:
                    let decision = await context.resolveItemError(ItemErrorRequest(
                        jobID: job.id, jobTitle: job.title, item: item, message: message,
                        isDiskError: FS.isDiskError(error)))
                    resolution = decision.resolution
                    if decision.applyToAll { errors.applied = decision.resolution }
                }
            }
            switch resolution {
            case .skip:
                context.journal.problem("Couldn’t \(verb) “\(item.lastPathComponent)”: \(message)")
                return false
            case .stopJob:
                throw error
            case .stopAll:
                throw FQError.stoppedAll(message)
            }
        }
    }

    private func transfer(_ sources: [URL], to destDir: URL, move: Bool, job: Job, context: ExecutionContext) async throws {
        guard FS.isDirectory(destDir) else { throw FQError.destinationMissing(destDir.path) }
        let destDisk = try diskResolver.disk(for: destDir)
        removeOwnLeftovers(in: destDir, jobID: job.id)

        let sizes = try await runBlocking { sources.map { FS.totalSize($0) } }
        context.progress.update {
            $0.totalBytes = sizes.reduce(0) { $0 + $1.bytes }
            $0.totalFiles = sizes.reduce(0) { $0 + $1.files }
        }

        let tally = Tally()
        let errors = ErrorChoice()
        var sticky = Sticky()
        let verb = move ? "move" : "copy"

        for (index, source) in sources.enumerated() {
            try await context.control.checkpoint()
            let size = sizes[index]
            let (baseBytes, baseFiles) = (tally.bytes, tally.files)
            defer {
                // Whatever happened to this item (copied, merged, skipped), it's now accounted for.
                tally.bytes = baseBytes
                tally.files = baseFiles
                tally.add(size, context)
            }
            context.progress.update { $0.currentItem = source.lastPathComponent }

            try await attempt(source, verb: verb, job: job, context: context, errors: errors) {
                guard FS.itemExists(source) else { throw FQError.sourceMissing(source.path) }
                if FS.isDirectory(source) && FS.isSameOrInside(destDir, source) {
                    throw FQError.intoItself(source.path)
                }
                let sameDisk = (try? diskResolver.disk(for: source).id) == destDisk.id

                var dest = destDir.appendingPathComponent(source.lastPathComponent)
                if FS.itemExists(dest) {
                    if FS.sameFile(source, dest) {
                        if move {
                            context.journal.note("“\(source.lastPathComponent)” is already in \(destDir.lastPathComponent)")
                            return
                        }
                        dest = FS.uniqueURL(dest) // duplicating in place
                    } else {
                        let bothFolders = FS.isMergeableFolder(source) && FS.isMergeableFolder(dest)
                        // An identical file is already there: nothing to copy (unless the user wants duplicates).
                        if !bothFolders, job.options.conflictPolicy != .keepBoth,
                           try await identical(source, dest, job: job) {
                            try await handleIdentical(source, existing: dest, move: move, context: context)
                            context.journal.note("“\(source.lastPathComponent)” was already there")
                            return
                        }
                        switch await resolve(source: source, existing: dest, canMerge: bothFolders, job: job, context: context, sticky: &sticky) {
                        case .merge:
                            let stats = MergeStats()
                            try await merge(source, into: dest, move: move, sameDisk: sameDisk, job: job, context: context,
                                            tally: tally, sticky: &sticky, errors: errors, stats: stats, journalChildren: true)
                            if move { removeIfEmpty(source) }
                            context.journal.note(mergeSummary(source.lastPathComponent, stats))
                            return
                        case .skip:
                            context.journal.note("Skipped “\(source.lastPathComponent)”")
                            return
                        case .keepBoth:
                            dest = FS.uniqueURL(dest)
                        case .replace:
                            let trashed = try trasher.trash(dest)
                            context.journal.record(.trashed(original: dest, trashURL: trashed, stamp: FS.stamp(trashed)))
                        }
                    }
                }
                let stats = MergeStats()
                try await place(source, at: dest, move: move, sameDisk: sameDisk, job: job, context: context,
                                tally: tally, errors: errors, stats: stats, journal: true)
            }
        }
        context.progress.update { $0.currentItem = nil }
    }

    /// Copies or moves one item to a destination name that is free, adding its size to the progress.
    /// Folders are copied item by item (into a new folder of the same name), so one unreadable file
    /// doesn't sink the whole folder — and an interrupted folder copy can be completed later by merging.
    private func place(_ source: URL, at dest: URL, move: Bool, sameDisk: Bool, job: Job, context: ExecutionContext,
                       tally: Tally, errors: ErrorChoice, stats: MergeStats, journal: Bool) async throws {
        if move && sameDisk {
            try FS.renameExclusive(source, dest)
            context.journal.record(.moved(from: source, to: dest, stamp: FS.stamp(dest)))
            tally.add(FS.totalSize(dest), context)
            stats.copied += 1
            return
        }
        if FS.isMergeableFolder(source) {
            // Read the folder's dates first: moving its contents out changes them.
            let originalTimes = FS.times(of: source)
            try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: false)
            var sticky = Sticky()
            do {
                // For a copy, the new folder is journaled as one item (undo removes it whole);
                // for a move, each file is journaled so undo can put them back individually.
                try await merge(source, into: dest, move: move, sameDisk: sameDisk, job: job, context: context,
                                tally: tally, sticky: &sticky, errors: errors, stats: stats, journalChildren: move)
            } catch {
                // Nothing made it into the new folder: don't leave an empty one behind.
                if (try? FileManager.default.contentsOfDirectory(atPath: dest.path))?.isEmpty == true {
                    try? FileManager.default.removeItem(at: dest)
                }
                throw error
            }
            // After its contents, since adding them changes the new folder's date.
            if let originalTimes { FS.setTimes(originalTimes, on: dest) }
            if move {
                removeIfEmpty(source)
            } else if journal {
                context.journal.record(.copied(from: source, to: dest, stamp: FS.stamp(dest)))
            }
            return
        }
        let size = FS.totalSize(source)
        try await copyItem(source, to: dest, baseBytes: tally.bytes, baseFiles: tally.files, context: context)
        if move {
            let checksums = job.options.verifyChecksums
            let ok = try await runBlocking { try FS.contentsMatch(source, dest, checksums: checksums) }
            guard ok else {
                try? FileManager.default.removeItem(at: dest)
                throw FQError.verificationFailed(source.path)
            }
            try await runBlocking { try FileManager.default.removeItem(at: source) }
            if journal { context.journal.record(.moved(from: source, to: dest, stamp: FS.stamp(dest))) }
        } else if journal {
            context.journal.record(.copied(from: source, to: dest, stamp: FS.stamp(dest)))
        }
        tally.add(size, context)
        stats.copied += size.files
    }

    /// Merges the contents of `source` into the existing folder `dest`: copies what's missing,
    /// leaves identical files alone, and resolves files that differ by the job's policy.
    /// Each item is attempted separately, so an unreadable one can be skipped.
    private func merge(_ source: URL, into dest: URL, move: Bool, sameDisk: Bool, job: Job, context: ExecutionContext,
                       tally: Tally, sticky: inout Sticky, errors: ErrorChoice, stats: MergeStats,
                       journalChildren: Bool) async throws {
        removeOwnLeftovers(in: dest, jobID: job.id)
        let all = try FileManager.default.contentsOfDirectory(at: source, includingPropertiesForKeys: nil, options: [])
        let names = Set(all.map(\.lastPathComponent))
        let children = all
            .filter { child in
                let name = child.lastPathComponent
                if name.hasSuffix(".fqpart") { return false } // our own unfinished copies
                // "._name" files are how FAT/exFAT disks store a file's Mac metadata; macOS recreates them.
                if name.hasPrefix("._"), names.contains(String(name.dropFirst(2))) { return false }
                return true
            }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        let verb = move ? "move" : "copy"

        for child in children {
            try await context.control.checkpoint()
            let target = dest.appendingPathComponent(child.lastPathComponent)
            context.progress.update { $0.currentItem = child.lastPathComponent }

            let ok = try await attempt(child, verb: verb, job: job, context: context, errors: errors) {
                if !FS.itemExists(target) {
                    try await place(child, at: target, move: move, sameDisk: sameDisk, job: job, context: context,
                                    tally: tally, errors: errors, stats: stats, journal: journalChildren)
                    return
                }
                if child.lastPathComponent == ".DS_Store" {
                    // Finder view settings: keep the destination's own.
                    tally.add(FS.totalSize(child), context)
                    if move { try? FileManager.default.removeItem(at: child) }
                    return
                }
                if FS.isMergeableFolder(child) && FS.isMergeableFolder(target) {
                    try await merge(child, into: target, move: move, sameDisk: sameDisk, job: job, context: context,
                                    tally: tally, sticky: &sticky, errors: errors, stats: stats, journalChildren: journalChildren)
                    if move { removeIfEmpty(child) }
                    return
                }
                if try await identical(child, target, job: job) {
                    tally.add(FS.totalSize(child), context)
                    try await handleIdentical(child, existing: target, move: move, context: context)
                    stats.alreadyThere += 1
                    return
                }
                // Same name, different content (e.g. a half-finished copy from earlier).
                switch await resolve(source: child, existing: target, canMerge: false, job: job, context: context, sticky: &sticky) {
                case .skip, .merge:
                    tally.add(FS.totalSize(child), context)
                    stats.skippedDifferent += 1
                    context.journal.note("Skipped “\(child.lastPathComponent)” (a different version is already there)")
                case .keepBoth:
                    let renamed = FS.uniqueURL(target)
                    try await place(child, at: renamed, move: move, sameDisk: sameDisk, job: job, context: context,
                                    tally: tally, errors: errors, stats: stats, journal: true)
                    stats.keptBoth += 1
                    context.journal.note("Kept both “\(child.lastPathComponent)”: the incoming one differs, saved as “\(renamed.lastPathComponent)”")
                case .replace:
                    let trashed = try trasher.trash(target)
                    context.journal.record(.trashed(original: target, trashURL: trashed, stamp: FS.stamp(trashed)))
                    try await place(child, at: target, move: move, sameDisk: sameDisk, job: job, context: context,
                                    tally: tally, errors: errors, stats: stats, journal: true)
                }
            }
            if !ok { tally.add(FS.totalSize(child), context) }
        }
    }

    /// Deletes unfinished copies this job left in `folder` on an earlier, interrupted run
    /// (hidden ".<name>.<job>.fqpart" items, plus their exFAT "._" companions).
    private func removeOwnLeftovers(in folder: URL, jobID: UUID) {
        let suffix = FS.partialSuffix(jobID: jobID)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return }
        for name in names where name.hasSuffix(suffix) {
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(name))
        }
    }

    /// Same file already at the destination. For a move, the original goes to the Trash (so undo can bring it back).
    private func handleIdentical(_ source: URL, existing: URL, move: Bool, context: ExecutionContext) async throws {
        guard move else { return }
        let trashed = try trasher.trash(source)
        context.journal.record(.trashed(original: source, trashURL: trashed, stamp: FS.stamp(trashed)))
    }

    private func identical(_ a: URL, _ b: URL, job: Job) async throws -> Bool {
        let checksums = job.options.verifyChecksums
        if job.options.conflictPolicy == .mergeKeepBoth && !checksums {
            return try await runBlocking { try FS.quickSameContents(a, b) }
        }
        return try await runBlocking { try FS.sameContents(a, b, checksums: checksums) }
    }

    /// After a merged move, the source folder is removed only if nothing was left behind in it.
    private func removeIfEmpty(_ folder: URL) {
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? ["?"]
        if contents.allSatisfy({ $0 == ".DS_Store" }) { try? FileManager.default.removeItem(at: folder) }
    }

    private func mergeSummary(_ name: String, _ stats: MergeStats) -> String {
        var parts = ["\(stats.copied) copied", "\(stats.alreadyThere) already there"]
        if stats.skippedDifferent > 0 { parts.append("\(stats.skippedDifferent) skipped (different version there)") }
        if stats.keptBoth > 0 { parts.append("\(stats.keptBoth) kept both (different content, renamed)") }
        return "Merged “\(name)”: " + parts.joined(separator: ", ")
    }

    private func copyItem(_ source: URL, to dest: URL, baseBytes: Int64, baseFiles: Int, context: ExecutionContext) async throws {
        let progress = context.progress
        let copier = Copier(control: context.control) { bytes, files in
            progress.update {
                $0.completedBytes = baseBytes + bytes
                $0.completedFiles = baseFiles + files
            }
        }
        // Copy under a hidden temporary name and rename only when complete, so an unfinished copy
        // (app quit, crash, disk pulled) never sits at the destination looking like the real item.
        // The name depends on the job, so a restarted job finds and replaces its own leftover.
        let partial = FS.partialURL(for: dest, jobID: context.jobID)
        do {
            try await runBlocking {
                if FS.itemExists(partial) { try FileManager.default.removeItem(at: partial) }
                try copier.copy(from: source, to: partial)
                // copyfile keeps most dates, but not created dates or the top folder's modified date.
                FS.copyDates(from: source, to: partial)
                try FS.renameExclusive(partial, dest)
            }
        } catch {
            if FS.itemExists(partial) { try? FileManager.default.removeItem(at: partial) }
            throw error
        }
    }

    private func resolve(
        source: URL, existing: URL, canMerge: Bool, job: Job, context: ExecutionContext, sticky: inout Sticky
    ) async -> ConflictResolution {
        if canMerge, let answer = sticky.folder { return answer }
        if !canMerge, let answer = sticky.file { return answer }
        switch job.options.conflictPolicy {
        case .skip: return .skip
        case .replace: return .replace
        case .keepBoth: return .keepBoth
        case .merge where canMerge, .mergeKeepBoth where canMerge: return .merge
        case .mergeKeepBoth: return .keepBoth
        case .merge, .ask:
            let request = ConflictRequest(
                jobID: job.id, jobTitle: job.title, source: source, existing: existing,
                sourceInfo: ItemInfo(url: source), existingInfo: ItemInfo(url: existing), canMerge: canMerge
            )
            let decision = await context.resolveConflict(request)
            var resolution = decision.resolution
            if resolution == .merge && !canMerge { resolution = .skip }
            if decision.applyToAll {
                if canMerge { sticky.folder = resolution } else { sticky.file = resolution }
            }
            return resolution
        }
    }

    // MARK: Rename

    private func rename(_ source: URL, to newName: String, job: Job, context: ExecutionContext) async throws {
        if let reason = FS.validateName(newName) { throw FQError.invalidName(reason) }
        guard FS.itemExists(source) else { throw FQError.sourceMissing(source.path) }
        context.progress.update { $0.totalFiles = 1; $0.currentItem = source.lastPathComponent }
        guard source.lastPathComponent != newName else {
            context.journal.note("Name unchanged")
            return
        }
        var dest = source.deletingLastPathComponent().appendingPathComponent(newName)
        if FS.itemExists(dest) && !FS.sameFile(source, dest) {
            var sticky = Sticky()
            switch await resolve(source: source, existing: dest, canMerge: false, job: job, context: context, sticky: &sticky) {
            case .skip, .merge:
                context.journal.note("Skipped “\(source.lastPathComponent)”")
                return
            case .keepBoth:
                dest = FS.uniqueURL(dest)
            case .replace:
                let trashed = try trasher.trash(dest)
                context.journal.record(.trashed(original: dest, trashURL: trashed, stamp: FS.stamp(trashed)))
            }
        }
        try FS.renameAllowingCaseChange(source, dest)
        context.journal.record(.renamed(from: source, to: dest, stamp: FS.stamp(dest)))
        context.progress.update { $0.completedFiles = 1; $0.currentItem = nil }
    }

    // MARK: Batch rename (all or nothing)

    private func batchRename(_ items: [RenamePlanItem], context: ExecutionContext) async throws {
        if items.contains(where: { $0.status.isError }) { throw FQError.planHasErrors }
        let work = items.filter { $0.status == .ok }
        context.progress.update { $0.totalFiles = work.count }

        struct Step { let original: URL; let temp: URL; let final: URL; var done = false }
        var steps: [Step] = []
        do {
            // Phase 1: move everything to unique temporary names, so swaps and cycles can't collide.
            for item in work {
                try await context.control.checkpoint()
                guard FS.itemExists(item.original) else { throw FQError.sourceMissing(item.original.path) }
                let temp = item.original.deletingLastPathComponent()
                    .appendingPathComponent(".fq-\(UUID().uuidString).tmp")
                try FS.renameExclusive(item.original, temp)
                steps.append(Step(original: item.original, temp: temp, final: item.destination))
            }
            // Phase 2: temporary → final names.
            for i in steps.indices {
                try await context.control.checkpoint()
                try FS.renameExclusive(steps[i].temp, steps[i].final)
                steps[i].done = true
                let count = i + 1
                context.progress.update { $0.completedFiles = count; $0.currentItem = steps[i].final.lastPathComponent }
            }
        } catch {
            // Roll back every name already changed, newest first.
            for step in steps.reversed() {
                let current = step.done ? step.final : step.temp
                try? FS.renameAllowingCaseChange(current, step.original)
            }
            throw error
        }
        for step in steps {
            context.journal.record(.renamed(from: step.original, to: step.final, stamp: FS.stamp(step.final)))
        }
    }

    // MARK: Trash

    private func trash(_ sources: [URL], job: Job, context: ExecutionContext) async throws {
        context.progress.update { $0.totalFiles = sources.count }
        let errors = ErrorChoice()
        for (i, source) in sources.enumerated() {
            try await context.control.checkpoint()
            try await attempt(source, verb: "move to the Trash", job: job, context: context, errors: errors) {
                guard FS.itemExists(source) else {
                    context.journal.note("“\(source.lastPathComponent)” was already gone")
                    return
                }
                let trashed = try trasher.trash(source)
                context.journal.record(.trashed(original: source, trashURL: trashed, stamp: FS.stamp(trashed)))
            }
            context.progress.update { $0.completedFiles = i + 1 }
        }
    }

    // MARK: Organize

    private func organize(_ items: [OrganizeItem], move: Bool, cleanUpIn: URL?, job: Job, context: ExecutionContext) async throws {
        let work = items.filter(\.status.willMove)
        let sizes = try await runBlocking { work.map { FS.totalSize($0.source) } }
        context.progress.update {
            $0.totalBytes = sizes.reduce(0) { $0 + $1.bytes }
            $0.totalFiles = sizes.reduce(0) { $0 + $1.files }
        }
        let tally = Tally()
        let errors = ErrorChoice()
        var sticky = Sticky()
        let stats = MergeStats()
        var diskOf: [URL: DiskID] = [:]
        func disk(_ dir: URL) -> DiskID? {
            if let d = diskOf[dir] { return d }
            let d = try? diskResolver.disk(for: dir).id
            diskOf[dir] = d
            return d
        }
        let verb = move ? "move" : "copy"

        for (index, item) in work.enumerated() {
            try await context.control.checkpoint()
            let (baseBytes, baseFiles) = (tally.bytes, tally.files)
            defer {
                tally.bytes = baseBytes
                tally.files = baseFiles
                tally.add(sizes[index], context)
            }
            context.progress.update { $0.currentItem = item.source.lastPathComponent }

            try await attempt(item.source, verb: verb, job: job, context: context, errors: errors) {
                guard FS.itemExists(item.source) else { throw FQError.sourceMissing(item.source.path) }
                let folder = item.destination.deletingLastPathComponent()
                try createFolders(folder, context: context)
                let sameDisk = disk(item.source.deletingLastPathComponent()) == disk(folder)
                var dest = item.destination
                if FS.itemExists(dest) {
                    if FS.sameFile(item.source, dest) { return }
                    let bothFolders = FS.isMergeableFolder(item.source) && FS.isMergeableFolder(dest)
                    if !bothFolders, job.options.conflictPolicy != .keepBoth, try await identical(item.source, dest, job: job) {
                        try await handleIdentical(item.source, existing: dest, move: move, context: context)
                        stats.alreadyThere += 1
                        return
                    }
                    switch await resolve(source: item.source, existing: dest, canMerge: bothFolders, job: job, context: context, sticky: &sticky) {
                    case .merge:
                        try await merge(item.source, into: dest, move: move, sameDisk: sameDisk, job: job, context: context,
                                        tally: tally, sticky: &sticky, errors: errors, stats: stats, journalChildren: true)
                        return
                    case .skip:
                        context.journal.note("Skipped “\(item.source.lastPathComponent)”")
                        return
                    case .keepBoth:
                        dest = FS.uniqueURL(dest)
                    case .replace:
                        let trashed = try trasher.trash(dest)
                        context.journal.record(.trashed(original: dest, trashURL: trashed, stamp: FS.stamp(trashed)))
                    }
                }
                try await place(item.source, at: dest, move: move, sameDisk: sameDisk, job: job, context: context,
                                tally: tally, errors: errors, stats: stats, journal: true)
            }
        }
        if move, let root = cleanUpIn {
            let removed = removeEmptyFolders(under: root, sources: work.map(\.source))
            if removed > 0 { context.journal.note("Removed \(removed) folder\(removed == 1 ? "" : "s") left empty") }
        }
        if stats.alreadyThere > 0 { context.journal.note("\(stats.alreadyThere) already in place") }
        context.progress.update { $0.currentItem = nil }
    }

    /// Creates `folder` and any missing parents, journaling each one so undo can remove it again.
    private func createFolders(_ folder: URL, context: ExecutionContext) throws {
        var missing: [URL] = []
        var probe = folder.standardizedFileURL
        while !FS.itemExists(probe), probe.path != "/" {
            missing.append(probe)
            probe = probe.deletingLastPathComponent()
        }
        for dir in missing.reversed() {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false)
            context.journal.record(.createdFolder(dir))
        }
    }

    /// After moving files out, removes the folders (under `root`, not `root` itself) that are now empty.
    private func removeEmptyFolders(under root: URL, sources: [URL]) -> Int {
        let rootPath = root.standardizedFileURL.path
        var candidates = Set<URL>()
        for source in sources {
            var dir = source.deletingLastPathComponent().standardizedFileURL
            while dir.path.hasPrefix(rootPath + "/") {
                candidates.insert(dir)
                dir = dir.deletingLastPathComponent()
            }
        }
        var removed = 0
        for dir in candidates.sorted(by: { $0.path.count > $1.path.count }) {
            let contents = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? ["?"]
            if contents.allSatisfy({ $0 == ".DS_Store" }), (try? FileManager.default.removeItem(at: dir)) != nil {
                removed += 1
            }
        }
        return removed
    }

    // MARK: Undo

    private func undo(_ entries: [JournalEntry], context: ExecutionContext) async throws {
        context.progress.update { $0.totalFiles = entries.count }
        for (i, entry) in entries.reversed().enumerated() {
            try await context.control.checkpoint()
            defer { context.progress.update { $0.completedFiles = i + 1 } }
            switch entry {
            case let .copied(_, to, stamp):
                guard FS.matches(to, stamp) else { skip(to, context); continue }
                _ = try trasher.trash(to)
            case let .moved(from, to, stamp):
                guard FS.matches(to, stamp) else { skip(to, context); continue }
                guard !FS.itemExists(from) else { occupied(from, context); continue }
                try await runBlocking {
                    try FileManager.default.createDirectory(at: from.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try FileManager.default.moveItem(at: to, to: from)
                }
            case let .renamed(from, to, stamp):
                guard FS.matches(to, stamp) else { skip(to, context); continue }
                if FS.itemExists(from) && !FS.sameFile(from, to) { occupied(from, context); continue }
                try FS.renameAllowingCaseChange(to, from)
            case let .createdFolder(url):
                let contents = (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? ["?"]
                if contents.allSatisfy({ $0 == ".DS_Store" }) { try? FileManager.default.removeItem(at: url) }
            case let .trashed(original, trashURL, stamp):
                guard FS.matches(trashURL, stamp) else { skip(trashURL, context); continue }
                guard !FS.itemExists(original) else { occupied(original, context); continue }
                try await runBlocking {
                    try FileManager.default.createDirectory(at: original.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try FileManager.default.moveItem(at: trashURL, to: original)
                }
            }
        }
    }

    private func skip(_ url: URL, _ context: ExecutionContext) {
        context.journal.note("Didn’t undo “\(url.lastPathComponent)”: it was changed or removed since")
    }

    private func occupied(_ url: URL, _ context: ExecutionContext) {
        context.journal.note("Didn’t undo “\(url.lastPathComponent)”: something else now has that name")
    }
}
