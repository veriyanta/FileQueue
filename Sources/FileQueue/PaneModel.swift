import AppKit
import FileQueueCore
import Observation

/// One side of the dual-pane window: a folder, its contents, selection and history.
@MainActor
@Observable
final class PaneModel {
    enum Side: String {
        case source, destination
        var title: String { self == .source ? "Source" : "Destination" }
    }

    let side: Side
    private(set) var folder: URL
    private(set) var entries: [DirectoryEntry] = []
    private(set) var error: String?
    /// The folder is on a disk that can't be changed (e.g. NTFS): nothing can be moved out, renamed, trashed or added.
    private(set) var isReadOnly = false
    var selection: Set<URL> = []
    var sortOrder: [KeyPathComparator<DirectoryEntry>] = [KeyPathComparator(\.name, comparator: .localizedStandard)] {
        didSet { entries = DirectoryLister.sorted(entries, by: sortOrder) }
    }
    var showHidden = false {
        didSet { refresh() }
    }

    enum ViewMode: String { case list, thumbnails }
    /// List or big thumbnails; remembered per pane.
    var viewMode: ViewMode = .list {
        didSet { UserDefaults.standard.set(viewMode.rawValue, forKey: "pane.\(side.rawValue).viewMode") }
    }
    /// Thumbnail size in points; remembered per pane.
    var thumbnailSize: Double = 180 {
        didSet { UserDefaults.standard.set(thumbnailSize, forKey: "pane.\(side.rawValue).thumbnailSize") }
    }

    private var backStack: [URL] = []
    private var forwardStack: [URL] = []
    @ObservationIgnored private var watcher: DispatchSourceFileSystemObject?

    private var defaultsKey: String { "pane.\(side.rawValue).folder" }

    init(side: Side, fallback: URL) {
        self.side = side
        var start = fallback
        if let saved = UserDefaults.standard.string(forKey: "pane.\(side.rawValue).folder"),
           FS.isDirectory(URL(fileURLWithPath: saved)) {
            start = URL(fileURLWithPath: saved)
        }
        folder = start.standardizedFileURL
        viewMode = ViewMode(rawValue: UserDefaults.standard.string(forKey: "pane.\(side.rawValue).viewMode") ?? "") ?? .list
        let size = UserDefaults.standard.double(forKey: "pane.\(side.rawValue).thumbnailSize")
        thumbnailSize = size >= 64 ? size : 180
        refresh()
        watch()
    }

    // MARK: Navigation

    var canGoBack: Bool { !backStack.isEmpty }
    var canGoForward: Bool { !forwardStack.isEmpty }
    var canGoUp: Bool { folder.path != "/" }

    /// The folder and its parents, nearest first (for the path menu).
    var ancestors: [URL] { DirectoryLister.ancestors(of: folder) }

    var displayName: String {
        folder.path == "/" ? (VolumeInfo.mounted().first?.name ?? "/") : FileManager.default.displayName(atPath: folder.path)
    }

    func open(_ url: URL) {
        let url = url.standardizedFileURL
        guard url != folder else { return }
        backStack.append(folder)
        forwardStack.removeAll()
        navigate(to: url)
    }

    func goBack() {
        guard let previous = backStack.popLast() else { return }
        forwardStack.append(folder)
        navigate(to: previous)
    }

    func goForward() {
        guard let next = forwardStack.popLast() else { return }
        backStack.append(folder)
        navigate(to: next)
    }

    func goUp() {
        guard canGoUp else { return }
        let child = folder
        open(folder.deletingLastPathComponent())
        selection = [child]
    }

    /// Opens the folder containing `urls` and selects them.
    func reveal(_ urls: [URL]) {
        guard let first = urls.first else { return }
        open(first.deletingLastPathComponent())
        selection = Set(urls.map(\.standardizedFileURL))
    }

    /// Selects everything shown in the folder.
    func selectAll() { selection = Set(entries.map(\.url)) }

    /// Double-click: folders open in the pane, files open in their default app.
    func activate(_ urls: Set<URL>) {
        let picked = entries.filter { urls.contains($0.url) }
        if picked.count == 1, let entry = picked.first, entry.isFolder {
            open(entry.url)
        } else {
            for entry in picked { NSWorkspace.shared.open(entry.url) }
        }
    }

    private func navigate(to url: URL) {
        folder = url
        selection = []
        refresh()
        watch()
        UserDefaults.standard.set(url.path, forKey: defaultsKey)
    }

    // MARK: Contents

    var selectedEntries: [DirectoryEntry] { entries.filter { selection.contains($0.url) } }
    var selectedURLs: [URL] { selectedEntries.map(\.url) }

    func refresh() {
        // If the folder was deleted, renamed or its disk ejected, fall back to the nearest folder that still exists.
        if !FS.isDirectory(folder), let existing = ancestors.dropFirst().first(where: { FS.isDirectory($0) }) {
            navigate(to: existing)
            return
        }
        isReadOnly = FS.isOnReadOnlyFileSystem(folder)
        do {
            entries = DirectoryLister.sorted(try DirectoryLister.list(folder, showHidden: showHidden), by: sortOrder)
            error = nil
        } catch {
            entries = []
            self.error = (error as NSError).localizedDescription
        }
        let present = Set(entries.map(\.url))
        selection = selection.intersection(present)
    }

    /// Re-lists the folder whenever something inside it is added, removed or renamed.
    private func watch() {
        watcher?.cancel()
        watcher = nil
        let fd = Darwin.open(folder.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.refresh() }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        watcher = source
    }

    /// If the folder disappeared (e.g. its disk was ejected), go to `fallback`.
    func ensureFolderExists(fallback: URL) {
        if !FS.isDirectory(folder) {
            backStack.removeAll()
            forwardStack.removeAll()
            navigate(to: fallback)
        }
    }
}
