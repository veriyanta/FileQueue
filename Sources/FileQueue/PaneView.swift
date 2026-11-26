import AppKit
import FileQueueCore
import SwiftUI
import UniformTypeIdentifiers

/// One side of the dual-pane window: a sidebar of favourites and disks, plus a folder browser.
struct PaneView: View {
    let pane: PaneModel
    @Environment(AppModel.self) private var model
    @ViewState private var isDropTarget = false

    var isActive: Bool { model.activeSide == pane.side }

    var body: some View {
        HSplitView {
            PaneSidebar(pane: pane)
                .frame(minWidth: 140, idealWidth: 170, maxWidth: 260)
            VStack(spacing: 0) {
                PaneHeader(pane: pane, isActive: isActive)
                Divider()
                switch pane.viewMode {
                case .list: FolderTable(pane: pane)
                case .thumbnails: FolderGrid(pane: pane)
                }
                Divider()
                PaneFooter(pane: pane)
            }
            .frame(minWidth: 300)
            .overlay {
                if isDropTarget {
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(Color.accentColor, lineWidth: 3)
                        .allowsHitTesting(false)
                }
            }
            .onDrop(of: [.fileURL], delegate: PaneDropDelegate(pane: pane, model: model, isTargeted: $isDropTarget))
        }
        .simultaneousGesture(TapGesture().onEnded { model.activeSide = pane.side })
        .onChange(of: pane.selection) { _, selection in
            if !selection.isEmpty { model.activeSide = pane.side }
        }
    }
}

/// Accepts file URLs dragged from the other pane or from Finder. Copies by default; ⌥ moves.
struct PaneDropDelegate: DropDelegate {
    let pane: PaneModel
    let model: AppModel
    @Binding var isTargeted: Bool

    func validateDrop(info: DropInfo) -> Bool {
        return info.hasItemsConforming(to: [.fileURL])
    }

    func dropEntered(info: DropInfo) { isTargeted = true }
    func dropExited(info: DropInfo) { isTargeted = false }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        return DropProposal(operation: NSEvent.modifierFlags.contains(.option) ? .move : .copy)
    }

    func performDrop(info: DropInfo) -> Bool {
        isTargeted = false
        let move = NSEvent.modifierFlags.contains(.option)
        let providers = info.itemProviders(for: [.fileURL])
        loadFileURLs(providers) { urls in
            model.drop(urls.isEmpty ? model.draggedURLs : urls, onto: pane, move: move)
            model.draggedURLs = []
        }
        return !providers.isEmpty
    }
}

/// Reads plain file URLs from a drop (no file data is copied).
@MainActor
func loadFileURLs(_ providers: [NSItemProvider], completion: @escaping @MainActor ([URL]) -> Void) {
    final class Collected: @unchecked Sendable {
        let lock = NSLock()
        var urls: [URL] = []
        func add(_ url: URL) { lock.withLock { urls.append(url) } }
    }
    let collected = Collected()
    let group = DispatchGroup()
    for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
        group.enter()
        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, error in
            var url: URL?
            if let u = item as? URL { url = u }
            else if let u = item as? NSURL { url = u as URL }
            else if let d = item as? Data { url = URL(dataRepresentation: d, relativeTo: nil) }
            else if let str = item as? String { url = URL(string: str) }
            if let url, url.isFileURL, !url.path.isEmpty { collected.add(url) }
            group.leave()
        }
    }
    group.notify(queue: .main) {
        let urls = collected.lock.withLock { collected.urls }
        MainActor.assumeIsolated { completion(urls) }
    }
}

// MARK: - Sidebar

struct PaneSidebar: View {
    let pane: PaneModel
    @Environment(AppModel.self) private var model

    var body: some View {
        List {
            Section("Favorites") {
                ForEach(model.favorites) { fav in
                    row(fav.name, systemImage: fav.symbol, url: fav.url)
                }
            }
            Section("Disks") {
                ForEach(model.volumes) { volume in
                    HStack(spacing: 4) {
                        row(volume.name, systemImage: volume.symbolName, url: volume.url)
                        if volume.isReadOnly {
                            Image(systemName: "lock.fill")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .help("Read-only: files can be copied from this disk, but not moved, renamed, deleted or added")
                                .accessibilityLabel("Read-only")
                        }
                        if volume.isEjectable {
                            Button { model.eject(volume) } label: {
                                Label("Eject \(volume.name)", systemImage: "eject.fill").labelStyle(.iconOnly)
                            }
                            .buttonStyle(.borderless)
                            .foregroundStyle(.secondary)
                            .help("Eject “\(volume.name)”")
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }

    /// Highlighted when this pane is inside that location (the deepest match wins).
    func row(_ title: String, systemImage: String, url: URL) -> some View {
        let isCurrent = bestMatch == url.standardizedFileURL
        return Button {
            pane.open(url)
            model.activeSide = pane.side
        } label: {
            Label(title, systemImage: systemImage)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.vertical, 2)
        .padding(.horizontal, 4)
        .background(RoundedRectangle(cornerRadius: 5).fill(isCurrent ? Color.accentColor.opacity(0.18) : .clear))
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
    }

    var bestMatch: URL? {
        let all = model.favorites.map(\.url) + model.volumes.map(\.url)
        return all.map(\.standardizedFileURL)
            .filter { FS.isSameOrInside(pane.folder, $0) }
            .max { $0.path.count < $1.path.count }
    }
}

// MARK: - Header

struct PaneHeader: View {
    let pane: PaneModel
    let isActive: Bool

    var body: some View {
        HStack(spacing: 6) {
            Text(pane.side.title.uppercased())
                .font(.caption.weight(.bold))
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Capsule().fill(isActive ? Color.accentColor : Color.secondary.opacity(0.25)))
                .foregroundStyle(isActive ? Color.white : Color.secondary)
                .accessibilityLabel("\(pane.side.title) pane\(isActive ? ", active" : "")")

            HStack(spacing: 2) {
                navButton("Back", "chevron.left", enabled: pane.canGoBack, action: pane.goBack)
                navButton("Forward", "chevron.right", enabled: pane.canGoForward, action: pane.goForward)
                navButton("Enclosing folder", "arrow.up", enabled: pane.canGoUp, action: pane.goUp)
            }

            Menu {
                ForEach(pane.ancestors, id: \.self) { url in
                    Button {
                        pane.open(url)
                    } label: {
                        Label {
                            Text(url.path == "/" ? "/" : FileManager.default.displayName(atPath: url.path))
                        } icon: {
                            Image(nsImage: icon(url))
                        }
                    }
                }
            } label: {
                Label(pane.displayName, systemImage: "folder.fill")
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .menuStyle(.borderlessButton)
            .fixedSize(horizontal: false, vertical: true)
            .help(pane.folder.path)

            Spacer(minLength: 4)
            Picker("View", selection: Binding(get: { pane.viewMode }, set: { pane.viewMode = $0 })) {
                Label("List", systemImage: "list.bullet").tag(PaneModel.ViewMode.list)
                Label("Thumbnails", systemImage: "square.grid.2x2").tag(PaneModel.ViewMode.thumbnails)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .help("Show as a list, or as big thumbnails to review the contents")
            Button { pane.refresh() } label: { Label("Refresh", systemImage: "arrow.clockwise").labelStyle(.iconOnly) }
                .buttonStyle(.borderless)
                .help("Refresh")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(isActive ? Color.accentColor.opacity(0.06) : Color.clear)
    }

    func navButton(_ title: String, _ symbol: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) { Label(title, systemImage: symbol).labelStyle(.iconOnly).frame(width: 18) }
            .buttonStyle(.borderless)
            .disabled(!enabled)
            .help(title)
    }

    func icon(_ url: URL) -> NSImage {
        let image = NSWorkspace.shared.icon(forFile: url.path)
        image.size = NSSize(width: 16, height: 16)
        return image
    }
}

// MARK: - Folder table

struct FolderTable: View {
    @Bindable var pane: PaneModel
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Table(of: DirectoryEntry.self, selection: $pane.selection, sortOrder: $pane.sortOrder) {
            TableColumn("Name", value: \.name, comparator: .localizedStandard) { entry in
                HStack(spacing: 6) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: entry.url.path))
                        .resizable()
                        .frame(width: 16, height: 16)
                        .accessibilityHidden(true)
                    Text(entry.name)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(entry.isHidden ? .secondary : .primary)
                }
            }
            .width(min: 140, ideal: 240)
            TableColumn("Date Modified", value: \.sortModified) { entry in
                Text(entry.modified.map(Format.date) ?? "—")
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .width(min: 110, ideal: 150)
            TableColumn("Kind", value: \.sortKind, comparator: .localizedStandard) { entry in
                Text(entry.kind)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .width(min: 70, ideal: 120)
            TableColumn("Size", value: \.sortSize) { entry in
                Text(entry.isFolder ? "—" : entry.size.map(Format.bytes) ?? "—")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .width(min: 60, ideal: 80, max: 110)
        } rows: {
            ForEach(pane.entries) { entry in
                // Drag a reference to the file (like Finder), so nothing is copied just to start a drag.
                // Dragging a multi-row selection sends every selected row.
                TableRow(entry)
                    .itemProvider {
                        // Dragging a selected row drags the whole selection.
                        MainActor.assumeIsolated {
                            model.draggedURLs = pane.selection.contains(entry.url) ? pane.selectedURLs : [entry.url]
                        }
                        return NSItemProvider(object: entry.url as NSURL)
                    }
            }
            // Drops onto the list itself (the table takes drags before the pane does).
            .onInsert(of: [.fileURL]) { _, providers in
                let move = NSEvent.modifierFlags.contains(.option)
                loadFileURLs(providers) { urls in model.drop(urls.isEmpty ? model.draggedURLs : urls, onto: pane, move: move) }
            }
        }
        .onCommand(#selector(NSResponder.selectAll(_:))) { pane.selectAll() }
        .contextMenu(forSelectionType: URL.self) { urls in
            if urls.isEmpty {
                Button("Select All") { model.activeSide = pane.side; pane.selectAll() }
                    .disabled(pane.entries.isEmpty)
            }
            if !urls.isEmpty {
                Button("Quick Look") { QuickLook.shared.show(Array(urls)) }
                Divider()
                Button(model.activeSide == .source ? "Copy to Destination" : "Copy to Source") { model.transferSelection(move: false) }
                Button(model.activeSide == .source ? "Move to Destination" : "Move to Source") { model.transferSelection(move: true) }
                    .disabled(pane.isReadOnly)
                Divider()
                Button("Rename…") { model.beginRename() }.disabled(pane.isReadOnly)
                Button("Batch Rename…") { model.beginBatchRename() }.disabled(pane.isReadOnly)
                Button("Organize into Folders…") { model.beginOrganize() }
                Button("Remove Empty Folders…") { openWindow(id: "emptyfolders", value: model.diskMapTarget) }.disabled(pane.isReadOnly)
                Button("Show Disk Map") { openWindow(id: "diskmap", value: model.diskMapTarget) }
                Button("Find Duplicates…") { openWindow(id: "duplicates", value: model.diskMapTarget) }
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting(Array(urls)) }
                Divider()
                Button("Move to Trash") { model.confirmTrash = true }.disabled(pane.isReadOnly)
            } else {
                Button("New Folder") { model.newFolder() }
                Button("Organize This Folder…") { model.activeSide = pane.side; pane.selection = []; model.beginOrganize() }
                Button("Remove Empty Folders in This Folder…") { openWindow(id: "emptyfolders", value: pane.folder) }.disabled(pane.isReadOnly)
                Button("Show Disk Map of This Folder") { openWindow(id: "diskmap", value: pane.folder) }
                Button("Find Duplicates in This Folder…") { openWindow(id: "duplicates", value: pane.folder) }
                Button(pane.showHidden ? "Hide Hidden Files" : "Show Hidden Files") { pane.showHidden.toggle() }
            }
        } primaryAction: { urls in
            pane.activate(urls)
        }
        .onDeleteCommand { if !pane.selection.isEmpty && !pane.isReadOnly { model.confirmTrash = true } }
        .onKeyPress(.space) {
            QuickLook.shared.toggle(pane.selectedURLs)
            return .handled
        }
        .overlay {
            if let error = pane.error {
                ContentUnavailableView("Can’t open this folder", systemImage: "lock", description: Text(error))
            } else if pane.entries.isEmpty {
                Text("Empty folder").foregroundStyle(.tertiary)
            }
        }
    }
}

// MARK: - Footer

struct PaneFooter: View {
    let pane: PaneModel

    var body: some View {
        HStack {
            if pane.isReadOnly {
                Label("Read-only disk", systemImage: "lock.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.orange)
                    .help("Files here can be copied, but not moved, renamed, deleted or added. macOS can't write to NTFS disks.")
            }
            Text(summary).font(.caption).foregroundStyle(.secondary)
            Spacer()
            if pane.viewMode == .thumbnails {
                Image(systemName: "photo").font(.caption2).foregroundStyle(.secondary)
                Slider(value: Binding(get: { pane.thumbnailSize }, set: { pane.thumbnailSize = $0 }), in: 80...420)
                    .controlSize(.mini)
                    .frame(width: 110)
                    .help("Thumbnail size")
                    .accessibilityLabel("Thumbnail size")
                Image(systemName: "photo").font(.callout).foregroundStyle(.secondary)
            }
            if let free = freeSpace {
                Text("\(Format.bytes(free)) free").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
    }

    var summary: String {
        let selected = pane.selectedEntries
        if selected.isEmpty { return "\(pane.entries.count) items" }
        let bytes = selected.compactMap(\.size).reduce(0, +)
        return "\(selected.count) of \(pane.entries.count) selected" + (bytes > 0 ? " · \(Format.bytes(bytes))" : "")
    }

    var freeSpace: Int64? {
        let values = try? pane.folder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }
}

