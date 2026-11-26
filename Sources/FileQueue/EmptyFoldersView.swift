import AppKit
import FileQueueCore
import SwiftUI

/// Finds empty folders under a folder and moves the ones you pick to the Trash (through the queue, so Undo works).
@MainActor @Observable final class EmptyFoldersModel {
    let folder: URL
    enum Phase { case idle, scanning, done }
    var phase: Phase = .idle
    var scanned = 0
    var folders: [URL] = []
    var unreadable = 0
    var picked: Set<URL> = []
    private var cancel = CancelFlag()

    init(folder: URL) { self.folder = folder.standardizedFileURL }

    func scan() {
        cancel.value = true
        let flag = CancelFlag()
        cancel = flag
        phase = .scanning
        scanned = 0
        let root = folder
        Task.detached(priority: .userInitiated) {
            let result = EmptyFolderFinder.find(in: root, isCancelled: { flag.value }) { n in
                Task { @MainActor [weak self] in if !flag.value { self?.scanned = n } }
            }
            await MainActor.run { [weak self] in
                guard let self, !flag.value else { return }
                self.folders = result.folders
                self.picked = Set(result.folders)
                self.unreadable = result.unreadable.count
                self.scanned = result.scanned
                self.phase = .done
            }
        }
    }

    func stop() {
        cancel.value = true
        if phase == .scanning { phase = .idle }
    }

    func relative(_ url: URL) -> String {
        let base = folder.path == "/" ? "" : folder.path
        return url.path.hasPrefix(base + "/") ? String(url.path.dropFirst(base.count + 1)) : url.path
    }

    /// The picked folders that are still empty right now.
    func confirmedPicks() -> (empty: [URL], changed: Int) {
        let chosen = folders.filter { picked.contains($0) }
        let empty = chosen.filter(EmptyFolderFinder.isStillEmpty)
        return (empty, chosen.count - empty.count)
    }

    func didTrash(_ urls: [URL]) {
        let gone = Set(urls)
        folders.removeAll { gone.contains($0) }
        picked.subtract(gone)
    }
}

struct EmptyFoldersWindow: View {
    let url: URL
    @ViewState private var empties: EmptyFoldersModel

    init(url: URL) {
        self.url = url
        _empties = ViewState(initialValue: EmptyFoldersModel(folder: url))
    }

    var body: some View {
        EmptyFoldersView(empties: empties)
            .frame(minWidth: 560, minHeight: 420)
            .onAppear { if empties.phase == .idle { empties.scan() } }
            .onDisappear { empties.stop() }
            .navigationTitle("Empty Folders — \(url.path == "/" ? "/" : url.lastPathComponent)")
    }
}

struct EmptyFoldersView: View {
    @Bindable var empties: EmptyFoldersModel
    @Environment(AppModel.self) private var model
    @ViewState private var pending: [URL]?
    @ViewState private var changedNote: String?

    var writable: Bool { FileManager.default.isWritableFile(atPath: empties.folder.path) }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .confirmationDialog(dialogTitle, isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } })) {
            Button("Move to Trash", role: .destructive) {
                if let urls = pending {
                    model.trash(urls)
                    empties.didTrash(urls)
                }
                pending = nil
            }
            Button("Cancel", role: .cancel) { pending = nil }
        } message: {
            Text((changedNote.map { $0 + " " } ?? "") + "They go through the queue, so Undo can bring them back.")
        }
    }

    var dialogTitle: String {
        let n = pending?.count ?? 0
        return "Move \(n) empty folder\(n == 1 ? "" : "s") to the Trash?"
    }

    var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "folder.badge.minus").font(.title2).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(empties.folder.path).font(.headline).lineLimit(1).truncationMode(.head)
                Text(statusText).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if empties.phase == .scanning {
                ProgressView().controlSize(.small)
                Button("Stop") { empties.stop() }
            } else {
                Button("Scan Again") { empties.scan() }
            }
        }
        .padding(12)
    }

    var statusText: String {
        switch empties.phase {
        case .idle: return "Not scanned"
        case .scanning: return "Looking through \(empties.scanned.formatted()) folders…"
        case .done:
            var text = "\(empties.folders.count.formatted()) empty folder\(empties.folders.count == 1 ? "" : "s") in \(empties.scanned.formatted()) looked at"
            if empties.unreadable > 0 { text += " · \(empties.unreadable) couldn’t be read (left alone)" }
            return text
        }
    }

    @ViewBuilder var content: some View {
        if empties.phase == .done && empties.folders.isEmpty {
            ContentUnavailableView("No empty folders", systemImage: "checkmark.circle",
                                   description: Text("Every folder in here holds something."))
                .frame(maxHeight: .infinity)
        } else {
            List {
                ForEach(empties.folders, id: \.self) { url in
                    Toggle(isOn: Binding(
                        get: { empties.picked.contains(url) },
                        set: { if $0 { empties.picked.insert(url) } else { empties.picked.remove(url) } }
                    )) {
                        Label(empties.relative(url), systemImage: "folder")
                            .lineLimit(1).truncationMode(.middle)
                    }
                    .toggleStyle(.checkbox)
                    .contextMenu {
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                    }
                }
            }
            .listStyle(.inset)
        }
    }

    var footer: some View {
        HStack(spacing: 10) {
            Text("Folders holding only .DS_Store, Thumbs.db or other system files count as empty, and so do folders holding only empty folders. Hidden folders and packages are left alone.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button("Select All") { empties.picked = Set(empties.folders) }
                .disabled(empties.folders.isEmpty || empties.picked.count == empties.folders.count)
            Button("Select None") { empties.picked = [] }
                .disabled(empties.picked.isEmpty)
            Button {
                let check = empties.confirmedPicks()
                changedNote = check.changed > 0
                    ? "\(check.changed) picked folder\(check.changed == 1 ? " isn’t" : "s aren’t") empty any more and will be left alone."
                    : nil
                if !check.empty.isEmpty { pending = check.empty } else if check.changed > 0 { empties.scan() }
            } label: {
                Label("Trash \(empties.picked.count) Folder\(empties.picked.count == 1 ? "" : "s")", systemImage: "trash")
            }
            .keyboardShortcut(.defaultAction)
            .disabled(empties.phase != .done || empties.picked.isEmpty || !writable)
            .help(writable ? "Move the ticked folders to the Trash" : "This disk is read-only")
        }
        .padding(12)
    }
}
