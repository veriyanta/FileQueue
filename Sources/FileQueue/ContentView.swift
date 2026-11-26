import FileQueueCore
import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        VSplitView {
            VStack(spacing: 0) {
                ActionBar()
                Divider()
                HSplitView {
                    PaneView(pane: model.source)
                        .frame(minWidth: 480)
                    PaneView(pane: model.destination)
                        .frame(minWidth: 480)
                }
            }
            .frame(minHeight: 320)

            QueuePanel()
                .frame(minHeight: 200)
        }
        .sheet(item: $model.renameTarget) { target in
            RenameSheet(url: target.url)
        }
        .sheet(item: Binding(
            get: { model.batchRenameFiles.map(BatchFiles.init) },
            set: { model.batchRenameFiles = $0?.urls }
        )) { files in
            BatchRenameView(files: files.urls)
        }
        .sheet(item: $model.organizeRequest) { request in
            OrganizeView(request: request)
        }
        .sheet(item: Binding(get: { model.conflicts.first }, set: { _ in })) { conflict in
            ConflictSheet(conflict: conflict)
                .interactiveDismissDisabled()
        }
        .sheet(item: Binding(get: { model.conflicts.isEmpty ? model.itemErrors.first : nil }, set: { _ in })) { pending in
            ItemErrorSheet(pending: pending)
                .interactiveDismissDisabled()
        }
        .confirmationDialog(
            "Move \(model.targets.count) item\(model.targets.count == 1 ? "" : "s") to the Trash?",
            isPresented: $model.confirmTrash
        ) {
            Button("Move to Trash", role: .destructive) { model.trashTargets() }
        } message: {
            Text("You can undo this, or put them back from the Trash.")
        }
        .alert("This clashes with a job in the queue", isPresented: Binding(
            get: { model.overlapPrompt != nil }, set: { if !$0 { model.overlapPrompt = nil } }
        )) {
            Button("Cancel", role: .cancel) { model.overlapPrompt = nil }
            Button("Add Anyway") { model.addAnyway() }
        } message: {
            Text(model.overlapPrompt?.message ?? "")
        }
        .alert("Something went wrong", isPresented: Binding(
            get: { model.alertMessage != nil }, set: { if !$0 { model.alertMessage = nil } }
        )) {
            Button("OK") { model.alertMessage = nil }
        } message: {
            Text(model.alertMessage ?? "")
        }
    }
}

struct BatchFiles: Identifiable {
    let urls: [URL]
    var id: [URL] { urls }
}

// MARK: - Action bar

struct ActionBar: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        @Bindable var model = model
        let toRight = model.activeSide == .source
        let count = model.targets.count
        HStack(spacing: 8) {
            Group {
                Button { model.transferSelection(move: false) } label: {
                    Label(toRight ? "Copy →" : "← Copy", systemImage: "doc.on.doc")
                }
                .help(model.otherPane.isReadOnly ? (model.readOnlyReason ?? "") : "Copy the selection to the \(model.otherPane.side.title.lowercased()) folder (⇧⌘C)")
                .disabled(!model.canCopy)
                Button { model.transferSelection(move: true) } label: {
                    Label(toRight ? "Move →" : "← Move", systemImage: "arrow.right.doc.on.clipboard")
                }
                .help(model.readOnlyReason.map { "\($0) — use Copy instead" } ?? "Move the selection to the \(model.otherPane.side.title.lowercased()) folder (⇧⌘M)")
                .disabled(!model.canMove)
            }

            Divider().frame(height: 18)
            Group {
                Button { model.beginRename() } label: { Label("Rename", systemImage: "pencil") }
                Button { model.beginBatchRename() } label: { Label("Batch Rename…", systemImage: "list.number") }
                Button(role: .destructive) { model.confirmTrash = true } label: { Label("Trash", systemImage: "trash") }
            }
            .disabled(!model.canModify)
            .help(model.activePane.isReadOnly ? (model.readOnlyReason ?? "") : "")
            Menu {
                Button("Organize into Folders…") { model.beginOrganize() }
                Button("Remove Empty Folders…") { openWindow(id: "emptyfolders", value: model.diskMapTarget) }
                    .disabled(model.activePane.isReadOnly)
            } label: {
                Label("Organize…", systemImage: "folder.badge.gearshape")
            } primaryAction: {
                model.beginOrganize()
            }
                .help("Sort files into folders by date, camera, type or name (⌥⌘O). Click the arrow to remove empty folders (⌥⌘E).")
                .disabled(model.activePane.isReadOnly && model.otherPane.isReadOnly)
            Button { model.newFolder() } label: { Label("New Folder", systemImage: "folder.badge.plus") }
                .disabled(model.activePane.isReadOnly)
            Button { openWindow(id: "diskmap", value: model.diskMapTarget) } label: {
                Label("Disk Map", systemImage: "square.grid.3x3.topleft.filled")
            }
            .help("See what takes up space in the selected folder (⌥⌘M)")
            Button { openWindow(id: "duplicates", value: model.diskMapTarget) } label: {
                Label("Duplicates", systemImage: "square.on.square")
            }
            .help("Find files with the same contents in the selected folder (⌥⌘D)")
            Button { model.swapPanes() } label: { Label("Swap", systemImage: "arrow.left.arrow.right") }
                .help("Swap the source and destination folders")

            Spacer(minLength: 12)
            if count > 0 {
                Text("\(count) selected in \(model.activeSide.title)")
                    .font(.callout).foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Picker("If exists:", selection: $model.defaultPolicy) {
                ForEach(ConflictPolicy.allCases) { Text($0.label).tag($0) }
            }
            .frame(width: model.defaultPolicy == .mergeKeepBoth ? 290 : 170)
            Toggle("Parallel anyway", isOn: $model.runInParallelAnyway)
                .toggleStyle(.checkbox)
                .fixedSize()
                .help("New jobs ignore the one-at-a-time-per-disk rule. Useful on fast SSDs.")
        }
        .labelStyle(.titleAndIcon)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

// MARK: - Rename sheet

struct RenameSheet: View {
    let url: URL
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @ViewState private var name = ""

    var original: String { url.lastPathComponent }

    var error: String? {
        if name == original { return nil }
        return FS.validateName(name)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Rename “\(original)”").font(.headline)
            TextField("New name", text: $name)
                .textFieldStyle(.roundedBorder)
                .frame(width: 360)
                .onSubmit(submit)
            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red).font(.callout)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Rename", action: submit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(error != nil || name == original)
            }
        }
        .padding(20)
        .onAppear { name = original }
    }

    func submit() {
        guard error == nil, name != original else { return }
        model.rename(url, to: name)
        dismiss()
    }
}

// MARK: - Conflict sheet

struct ConflictSheet: View {
    let conflict: PendingConflict
    @Environment(AppModel.self) private var model
    @ViewState private var applyToAll = false

    var body: some View {
        let r = conflict.request
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.largeTitle).foregroundStyle(.yellow)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text("“\(r.existing.lastPathComponent)” already exists in “\(r.existing.deletingLastPathComponent().lastPathComponent)”")
                        .font(.headline)
                    Text(r.jobTitle).foregroundStyle(.secondary).font(.callout)
                }
            }
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                GridRow {
                    Text("")
                    Text("Size").foregroundStyle(.secondary)
                    Text("Modified").foregroundStyle(.secondary)
                }
                GridRow {
                    Text("New (from \(r.source.deletingLastPathComponent().lastPathComponent))").bold()
                    Text(describe(size: r.sourceInfo))
                    Text(r.sourceInfo.modified.map(Format.date) ?? "—")
                }
                GridRow {
                    Text("Existing").bold()
                    Text(describe(size: r.existingInfo))
                    Text(r.existingInfo.modified.map(Format.date) ?? "—")
                }
            }
            .font(.callout)
            Toggle(r.canMerge ? "Apply to all remaining folders in this job" : "Apply to all remaining files in this job", isOn: $applyToAll)
            Text("Replacing moves the existing \(r.canMerge ? "folder" : "item") to the Trash.")
                .font(.caption).foregroundStyle(.secondary)
            if r.canMerge {
                Text("Merge copies only what’s missing into the existing folder. Files already there with the same size and date are left alone.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button("Skip") { decide(.skip) }
                Spacer()
                if r.canMerge {
                    Button("Keep Both") { decide(.keepBoth) }
                    Button("Replace") { decide(.replace) }
                    Button("Merge") { decide(.merge) }.keyboardShortcut(.defaultAction)
                } else {
                    Button("Keep Both") { decide(.keepBoth) }.keyboardShortcut(.defaultAction)
                    Button("Replace") { decide(.replace) }
                }
            }
        }
        .padding(20)
        .frame(width: 480)
    }

    func describe(size info: ItemInfo) -> String {
        info.isDirectory ? "Folder" : info.size.map(Format.bytes) ?? "—"
    }

    func decide(_ resolution: ConflictResolution) {
        model.resolveConflict(conflict, ConflictDecision(resolution, applyToAll: applyToAll))
    }
}

// MARK: - Item error sheet

struct ItemErrorSheet: View {
    let pending: PendingItemError
    @Environment(AppModel.self) private var model
    @ViewState private var applyToAll = false

    var body: some View {
        let r = pending.request
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "exclamationmark.octagon.fill")
                    .font(.largeTitle).foregroundStyle(.red)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Couldn’t process “\(r.item.lastPathComponent)”").font(.headline)
                    Text(r.message).font(.callout)
                    Text(r.jobTitle).foregroundStyle(.secondary).font(.caption)
                    Text((r.item.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath)
                        .foregroundStyle(.secondary).font(.caption)
                        .lineLimit(1).truncationMode(.middle)
                }
            }
            if r.isDiskError {
                Label("The disk reported a read/write error. The item may be damaged, or the disk may have bad sectors. For an NTFS disk, running “chkdsk /f” on Windows can often repair it.",
                      systemImage: "info.circle")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Toggle("Do the same for other errors in this job", isOn: $applyToAll)
            HStack {
                Button("Stop All") { decide(.stopAll) }
                    .help("Stop this job and put the rest of the queue on hold")
                Spacer()
                Button("Stop This Job") { decide(.stopJob) }
                    .help("Stop this job; other jobs in the queue continue")
                Button("Skip & Continue") { decide(.skip) }
                    .keyboardShortcut(.defaultAction)
                    .help("Leave this item out and carry on with the rest")
            }
            Text("Skipped items are listed on the job when it finishes. Retry then fetches only what’s missing.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(width: 500)
    }

    func decide(_ resolution: ItemErrorResolution) {
        model.resolveItemError(pending, ItemErrorDecision(resolution, applyToAll: applyToAll))
    }
}

// MARK: - Formatting

enum Format {
    static func bytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }

    static func date(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }

    static func duration(_ seconds: Double) -> String {
        let f = DateComponentsFormatter()
        f.allowedUnits = seconds >= 3600 ? [.hour, .minute] : [.minute, .second]
        f.unitsStyle = .abbreviated
        return f.string(from: seconds) ?? ""
    }
}
