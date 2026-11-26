import AppKit
import FileQueueCore
import Observation
import SwiftUI
import UserNotifications

enum SettingsKey {
    static let maxConcurrent = "maxConcurrent"
    static let defaultPolicy = "defaultConflictPolicy"
    static let verifyChecksums = "verifyChecksums"
    static let showMenuBar = "showMenuBarItem"
    static let onError = "onItemError"
}

struct PendingItemError: Identifiable {
    let request: ItemErrorRequest
    let continuation: CheckedContinuation<ItemErrorDecision, Never>
    var id: UUID { request.id }
}

struct PendingConflict: Identifiable {
    let request: ConflictRequest
    let continuation: CheckedContinuation<ConflictDecision, Never>
    var id: UUID { request.id }
}

/// One lane in the queue panel: jobs that share disks, in queue order. Each job is in exactly one lane.
struct Lane: Identifiable {
    let disks: [DiskInfo]
    let jobs: [Job]
    var id: String { disks.map(\.id.rawValue).joined(separator: "+") }
}

struct RenameTarget: Identifiable {
    let url: URL
    var id: URL { url }
}

struct Favorite: Identifiable, Hashable {
    let name: String
    let url: URL
    let symbol: String
    var id: URL { url }
}

@MainActor
@Observable
final class AppModel {
    static let shared = AppModel()

    let engine: QueueEngine

    // Dual panes
    let source: PaneModel
    let destination: PaneModel
    /// The pane actions apply to (the one last clicked or selected in).
    var activeSide: PaneModel.Side = .source
    private(set) var volumes: [VolumeInfo] = []
    let favorites: [Favorite]

    // Queue & sheets
    private(set) var jobs: [Job] = []
    var conflicts: [PendingConflict] = []
    var itemErrors: [PendingItemError] = []
    var alertMessage: String?
    var renameTarget: RenameTarget?
    var batchRenameFiles: [URL]?
    var organizeRequest: OrganizeRequest?
    var confirmTrash = false
    var runInParallelAnyway = false
    /// Files being dragged out of a pane. SwiftUI's in-app table drags can arrive with empty
    /// file-URL data, so drops fall back to this list.
    @ObservationIgnored var draggedURLs: [URL] = []

    var defaultPolicy: ConflictPolicy {
        didSet { UserDefaults.standard.set(defaultPolicy.rawValue, forKey: SettingsKey.defaultPolicy) }
    }
    var maxConcurrent: Int {
        didSet {
            UserDefaults.standard.set(maxConcurrent, forKey: SettingsKey.maxConcurrent)
            let value = maxConcurrent
            Task { await engine.setMaxConcurrent(value) }
        }
    }
    var verifyChecksums: Bool {
        didSet { UserDefaults.standard.set(verifyChecksums, forKey: SettingsKey.verifyChecksums) }
    }
    var onError: ErrorPolicy {
        didSet { UserDefaults.standard.set(onError.rawValue, forKey: SettingsKey.onError) }
    }

    private var previousStates: [UUID: JobState] = [:]
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    init() {
        let defaults = UserDefaults.standard
        defaults.register(defaults: [
            SettingsKey.maxConcurrent: 4,
            SettingsKey.defaultPolicy: ConflictPolicy.merge.rawValue,
            SettingsKey.verifyChecksums: false,
            SettingsKey.showMenuBar: true,
            SettingsKey.onError: ErrorPolicy.ask.rawValue,
        ])
        defaultPolicy = ConflictPolicy(rawValue: defaults.string(forKey: SettingsKey.defaultPolicy) ?? "") ?? .merge
        let limit = defaults.integer(forKey: SettingsKey.maxConcurrent)
        maxConcurrent = limit
        verifyChecksums = defaults.bool(forKey: SettingsKey.verifyChecksums)
        onError = ErrorPolicy(rawValue: defaults.string(forKey: SettingsKey.onError) ?? "") ?? .ask

        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        func dir(_ d: FileManager.SearchPathDirectory) -> URL { fm.urls(for: d, in: .userDomainMask).first ?? home }
        favorites = [
            Favorite(name: NSUserName(), url: home, symbol: "house"),
            Favorite(name: "Desktop", url: dir(.desktopDirectory), symbol: "menubar.dock.rectangle"),
            Favorite(name: "Documents", url: dir(.documentDirectory), symbol: "doc"),
            Favorite(name: "Downloads", url: dir(.downloadsDirectory), symbol: "arrow.down.circle"),
            Favorite(name: "Applications", url: URL(fileURLWithPath: "/Applications"), symbol: "square.grid.2x2"),
        ]
        source = PaneModel(side: .source, fallback: home)
        destination = PaneModel(side: .destination, fallback: dir(.desktopDirectory))
        volumes = VolumeInfo.mounted()

        engine = QueueEngine(store: JSONQueueStore(), maxConcurrent: limit)
        let engine = self.engine
        let handler: ConflictHandler = { [weak self] request in
            guard let self else { return ConflictDecision(.skip) }
            return await self.askConflict(request)
        }
        let errorHandler: ItemErrorHandler = { [weak self] request in
            guard let self else { return ItemErrorDecision(.stopJob) }
            return await self.askItemError(request)
        }
        Task { [weak self] in
            await engine.setConflictHandler(handler)
            await engine.setItemErrorHandler(errorHandler)
            for await jobs in await engine.updates() {
                guard let self else { return }
                self.receive(jobs)
            }
        }

        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.didUnmountNotification, object: nil, queue: .main) { [weak self] note in
            let path = (note.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL)?.path
            if let path { Task { await engine.handleUnmount(volumePath: path) } }
            MainActor.assumeIsolated { self?.volumesChanged() }
        })
        observers.append(center.addObserver(forName: NSWorkspace.didMountNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.volumesChanged() }
        })

        if Bundle.main.bundleIdentifier != nil {
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
    }

    private func volumesChanged() {
        volumes = VolumeInfo.mounted()
        let home = FileManager.default.homeDirectoryForCurrentUser
        source.ensureFolderExists(fallback: home)
        destination.ensureFolderExists(fallback: home)
    }

    // MARK: Panes

    var activePane: PaneModel { activeSide == .source ? source : destination }
    var otherPane: PaneModel { activeSide == .source ? destination : source }
    func pane(_ side: PaneModel.Side) -> PaneModel { side == .source ? source : destination }

    /// Files dropped on the Dock icon or opened with "Open With": show them in the source pane.
    func reveal(_ urls: [URL]) {
        activeSide = .source
        source.reveal(urls)
    }

    func swapPanes() {
        let left = source.folder
        let right = destination.folder
        source.open(right)
        destination.open(left)
    }

    func eject(_ volume: VolumeInfo) {
        Task.detached {
            do {
                try NSWorkspace.shared.unmountAndEjectDevice(at: volume.url)
            } catch {
                await MainActor.run { self.alertMessage = "Couldn’t eject “\(volume.name)”: \(error.localizedDescription)" }
            }
        }
    }

    // MARK: Engine updates

    private func receive(_ jobs: [Job]) {
        var somethingFinished = false
        for job in jobs {
            let before = previousStates[job.id]
            if let before, before.isStarted, job.state.isFinished {
                somethingFinished = true
                if job.state == .completed || isFailed(job.state) { notifyIfInBackground(job) }
            }
            previousStates[job.id] = job.state
        }
        self.jobs = jobs
        if somethingFinished {
            source.refresh()
            destination.refresh()
        }
    }

    private func isFailed(_ state: JobState) -> Bool {
        if case .failed = state { return true }
        return false
    }

    private func notifyIfInBackground(_ job: Job) {
        guard !NSApp.isActive, Bundle.main.bundleIdentifier != nil else { return }
        let content = UNMutableNotificationContent()
        if case let .failed(reason) = job.state {
            content.title = "Failed: \(job.title)"
            content.body = reason
        } else {
            content.title = "Done"
            content.body = job.title
        }
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: job.id.uuidString, content: content, trigger: nil))
    }

    // MARK: Derived state for the queue panel

    var lanes: [Lane] {
        let active = jobs.filter { $0.state.isQueued || $0.state.isStarted || $0.state == .onHold }
        return LaneGrouping.group(active).map { Lane(disks: $0.disks, jobs: $0.jobs) }
    }

    /// Failed, interrupted, or finished with items that couldn't be copied.
    var needsAttention: [Job] {
        jobs.filter {
            if case .failed = $0.state { return true }
            return $0.state == .interrupted || ($0.state == .completed && !$0.problems.isEmpty)
        }
    }

    var finished: [Job] {
        jobs.filter { ($0.state == .completed && $0.problems.isEmpty) || $0.state == .cancelled }
            .sorted { ($0.finishedAt ?? .distantPast) > ($1.finishedAt ?? .distantPast) }
    }

    var runningJobs: [Job] { jobs.filter(\.state.isStarted) }
    var hasActiveJobs: Bool { jobs.contains { $0.state.isQueued || $0.state.isStarted } }
    var canUndo: Bool { jobs.contains(where: \.canUndo) }

    var overallProgress: Double? {
        let active = runningJobs
        guard !active.isEmpty else { return nil }
        return active.reduce(0.0) { $0 + $1.progress.fraction } / Double(active.count)
    }

    // MARK: Actions

    /// Selected items in the active pane.
    var targets: [URL] { activePane.selectedURLs }

    var canTransfer: Bool { canCopy }
    var canCopy: Bool { !targets.isEmpty && activePane.folder != otherPane.folder && !otherPane.isReadOnly }
    var canMove: Bool { canCopy && !activePane.isReadOnly }
    /// Rename, batch rename, trash: need a selection on a writable disk.
    var canModify: Bool { !targets.isEmpty && !activePane.isReadOnly }

    /// Why the actions are unavailable, for button tooltips.
    var readOnlyReason: String? {
        if activePane.isReadOnly { return "\(activePane.displayName) is on a read-only disk" }
        if otherPane.isReadOnly { return "The \(otherPane.side.title.lowercased()) folder is on a read-only disk" }
        return nil
    }

    private var options: JobOptions {
        JobOptions(conflictPolicy: defaultPolicy, runInParallelAnyway: runInParallelAnyway,
                   verifyChecksums: verifyChecksums, onError: onError)
    }

    /// Copy or move the active pane's selection into the other pane's folder.
    func transferSelection(move: Bool) {
        guard move ? canMove : canCopy else { return }
        transfer(targets, to: otherPane.folder, move: move)
        activePane.selection = []
    }

    /// Items dropped onto a pane (from the other pane or from Finder) are copied there; hold ⌥ to move.
    func drop(_ urls: [URL], onto pane: PaneModel, move: Bool) {
        let items = urls.filter(\.isFileURL).map(\.standardizedFileURL)
        // Dropping items back into the folder they came from does nothing.
        let fromElsewhere = items.filter { $0.deletingLastPathComponent() != pane.folder }
        guard !fromElsewhere.isEmpty else { return }
        activeSide = pane.side
        transfer(fromElsewhere, to: pane.folder, move: move)
    }

    private func transfer(_ sources: [URL], to folder: URL, move: Bool) {
        submit(move ? .move(sources: sources, destinationDir: folder) : .copy(sources: sources, destinationDir: folder))
    }

    func beginRename() {
        let urls = targets
        if urls.count == 1 { renameTarget = RenameTarget(url: urls[0]) }
        else if urls.count > 1 { batchRenameFiles = urls }
    }

    func rename(_ url: URL, to newName: String) {
        submit(.rename(source: url, newName: newName))
    }

    func beginBatchRename() {
        let urls = targets
        guard !urls.isEmpty else { return }
        batchRenameFiles = urls
    }

    func batchRename(_ plan: [RenamePlanItem], allowOverlap: Bool = false) async -> EnqueueOutcome {
        await enqueueAndWait(.batchRename(items: plan), allowOverlap: allowOverlap)
    }

    /// Organize the selected items — or, with nothing selected, everything in the active pane's folder.
    /// A single selected folder is organized from the inside.
    func beginOrganize() {
        let pane = activePane
        let selected = pane.selectedURLs
        let inputs: [URL]
        let root: URL
        if selected.count == 1, FS.isMergeableFolder(selected[0]) {
            inputs = [selected[0]]
            root = selected[0]
        } else if selected.isEmpty {
            inputs = pane.entries.map(\.url)
            root = pane.folder
        } else {
            inputs = selected
            root = pane.folder
        }
        guard !inputs.isEmpty else { return }
        organizeRequest = OrganizeRequest(inputs: inputs, root: root, otherFolder: otherPane.folder)
    }

    enum EnqueueOutcome: Equatable {
        case added
        case failed(String)
        /// It clashes with a job still in the queue; can be added anyway.
        case overlaps(String)

        var message: String? {
            switch self {
            case .added: nil
            case let .failed(m), let .overlaps(m): m
            }
        }
    }

    /// Adds the organize job and waits until it's in the queue.
    func organize(_ items: [OrganizeItem], move: Bool, cleanUpIn: URL?, allowOverlap: Bool = false) async -> EnqueueOutcome {
        let outcome = await enqueueAndWait(.organize(items: items, move: move, cleanUpIn: cleanUpIn), allowOverlap: allowOverlap)
        if outcome == .added { activePane.selection = [] }
        return outcome
    }

    /// Adds a job and waits until it's in the queue (preparing a big job can take a moment).
    func enqueueAndWait(_ operation: FileOperation, allowOverlap: Bool = false) async -> EnqueueOutcome {
        do {
            try await engine.enqueue(operation, options: options, allowOverlap: allowOverlap)
            return .added
        } catch let error as FQError {
            if case .overlapsQueuedJob = error { return .overlaps(error.localizedDescription) }
            return .failed(error.localizedDescription)
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    /// A job from the toolbar that clashes with a queued job, waiting for "Add Anyway" or "Cancel".
    var overlapPrompt: (operation: FileOperation, message: String)?

    func addAnyway() {
        guard let prompt = overlapPrompt else { return }
        overlapPrompt = nil
        Task {
            if case let .failed(message) = await enqueueAndWait(prompt.operation, allowOverlap: true) { alertMessage = message }
        }
    }

    /// Move specific items to the Trash through the queue (e.g. from the disk map).
    func trash(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        submit(.trash(sources: urls))
    }

    /// The folder to map: a single selected folder, otherwise the active pane's folder.
    var diskMapTarget: URL {
        let selected = activePane.selectedURLs
        if selected.count == 1, FS.isDirectory(selected[0]) { return selected[0] }
        return activePane.folder
    }

    func trashTargets() {
        let urls = targets
        guard !urls.isEmpty else { return }
        submit(.trash(sources: urls))
        activePane.selection = []
    }

    /// Creates "untitled folder" in the active pane right away, selects it and offers to rename it.
    func newFolder() {
        let pane = activePane
        guard !pane.isReadOnly else { return }
        let url = DirectoryLister.newFolderURL(in: pane.folder)
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
            pane.refresh()
            pane.selection = [url.standardizedFileURL]
            renameTarget = RenameTarget(url: url.standardizedFileURL)
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    private func submit(_ operation: FileOperation) {
        Task {
            switch await enqueueAndWait(operation) {
            case .added: break
            case let .failed(message): alertMessage = message
            case let .overlaps(message): overlapPrompt = (operation, message)
            }
        }
    }

    // MARK: Queue controls

    func pause(_ job: Job) { Task { await engine.pause(job.id) } }
    func resume(_ job: Job) { Task { await engine.resume(job.id) } }
    func cancel(_ job: Job) { Task { await engine.cancel(job.id) } }
    func retry(_ job: Job) { Task { await engine.retry(job.id) } }
    func remove(_ job: Job) { Task { await engine.remove(job.id) } }
    func move(_ job: Job, by offset: Int) { Task { await engine.move(job.id, by: offset) } }
    func pauseAll() { Task { await engine.pauseAll() } }
    func resumeAll() { Task { await engine.resumeAll() } }
    func clearFinished() { Task { await engine.clearFinished() } }

    func undo(_ job: Job) {
        Task {
            do { try await engine.undo(job.id) } catch { alertMessage = error.localizedDescription }
        }
    }

    func undoLast() {
        Task {
            do { try await engine.undoLast() } catch { alertMessage = error.localizedDescription }
        }
    }

    // MARK: Conflicts

    func askConflict(_ request: ConflictRequest) async -> ConflictDecision {
        NSApp.requestUserAttention(.informationalRequest)
        return await withCheckedContinuation { continuation in
            conflicts.append(PendingConflict(request: request, continuation: continuation))
        }
    }

    func askItemError(_ request: ItemErrorRequest) async -> ItemErrorDecision {
        NSApp.requestUserAttention(.criticalRequest)
        return await withCheckedContinuation { continuation in
            itemErrors.append(PendingItemError(request: request, continuation: continuation))
        }
    }

    func resolveItemError(_ pending: PendingItemError, _ decision: ItemErrorDecision) {
        itemErrors.removeAll { $0.id == pending.id }
        pending.continuation.resume(returning: decision)
    }

    func resolveConflict(_ conflict: PendingConflict, _ decision: ConflictDecision) {
        conflicts.removeAll { $0.id == conflict.id }
        conflict.continuation.resume(returning: decision)
    }
}
