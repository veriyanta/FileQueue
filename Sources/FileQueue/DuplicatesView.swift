import AppKit
import FileQueueCore
import SwiftUI

/// Finds files in a folder that look like copies of each other, shows them side by side with previews,
/// and offers next steps (keep one of each, trash the rest — checked byte for byte first).
@MainActor @Observable
final class DuplicatesModel {
    enum Phase: Equatable { case idle, scanning, verifying, done }

    let folder: URL
    var options = DuplicateFinder.Options(minimumSize: 1024)
    var rule: KeepRule = .bestName { didSet { applyRule() } }
    private(set) var phase: Phase = .idle
    private(set) var status = ""
    private(set) var groups: [DuplicateGroup] = []
    /// The copies to keep, per group. A group where every copy is kept is left alone.
    var keep: [UUID: Set<URL>] = [:]
    /// Files already sent to the Trash from this window.
    private(set) var trashedCount = 0
    private var task: Task<Void, Never>?
    private let cancelled = CancelFlag()

    init(folder: URL) { self.folder = folder }

    var extraFiles: [URL] {
        groups.flatMap { g in g.files.map(\.url).filter { !(keep[g.id] ?? []).contains($0) } }
    }
    var extraBytes: Int64 {
        groups.reduce(0) { total, g in total + Int64(g.files.filter { !(keep[g.id] ?? []).contains($0.url) }.count) * g.size }
    }
    var unverifiedCount: Int { groups.filter { !$0.verified }.count }
    var isBusy: Bool { phase == .scanning || phase == .verifying }

    func scan() {
        stop()
        cancelled.value = false
        phase = .scanning
        status = "Listing files…"
        groups = []
        keep = [:]
        let folder = folder, options = options, flag = cancelled
        task = Task {
            let found = await Task.detached(priority: .userInitiated) {
                DuplicateFinder.find(in: folder, options: options, progress: { p in
                    let text = p.phase == .listing ? "Listing files… \(p.done.formatted())"
                        : "Comparing \(p.done.formatted()) of \(p.total.formatted()) same-sized files"
                    Task { @MainActor in self.updateStatus(text, phase: .scanning) }
                }, isCancelled: { flag.value })
            }.value
            guard !flag.value else { return }
            groups = found
            applyRule()
            phase = .done
            status = ""
        }
    }

    private func updateStatus(_ text: String, phase: Phase) {
        if self.phase == phase { status = text }
    }

    func stop() {
        cancelled.value = true
        task?.cancel()
        if isBusy { phase = groups.isEmpty ? .idle : .done }
    }

    func applyRule() {
        for g in groups {
            if let k = DuplicateFinder.keeper(of: g, rule: rule) { keep[g.id] = [k.url] }
        }
    }

    /// Click a copy: keep it (it's added to the kept set; clicking a kept one un-keeps it, unless it's the last).
    func toggleKeep(_ file: DuplicateFile, in group: DuplicateGroup) {
        var set = keep[group.id] ?? []
        if set.contains(file.url) {
            if set.count > 1 { set.remove(file.url) }
        } else {
            set.insert(file.url)
        }
        keep[group.id] = set
    }

    func keepOnly(_ file: DuplicateFile, in group: DuplicateGroup) { keep[group.id] = [file.url] }
    func keepAll(_ group: DuplicateGroup) { keep[group.id] = Set(group.files.map(\.url)) }

    /// Compares every byte of the groups that only matched on samples. Groups can split or disappear.
    func verifyAll() async {
        let pending = groups.filter { !$0.verified }
        guard !pending.isEmpty else { return }
        cancelled.value = false
        phase = .verifying
        let flag = cancelled
        var index = 0
        for group in pending {
            index += 1
            status = "Checking every byte: group \(index) of \(pending.count) (\(Format.bytes(group.size)) each)"
            let result = await Task.detached(priority: .userInitiated) { DuplicateFinder.verify(group, isCancelled: { flag.value }) }.value
            if flag.value { break }
            replace(group, with: result)
        }
        phase = .done
        status = ""
    }

    private func replace(_ group: DuplicateGroup, with result: [DuplicateGroup]) {
        guard let i = groups.firstIndex(where: { $0.id == group.id }) else { return }
        let kept = keep.removeValue(forKey: group.id) ?? []
        groups.replaceSubrange(i...i, with: result)
        for g in result {
            let stillKept = kept.intersection(g.files.map(\.url))
            keep[g.id] = stillKept.isEmpty ? DuplicateFinder.keeper(of: g, rule: rule).map { [$0.url] } ?? [] : stillKept
        }
    }

    /// Verifies (if needed) and returns the files that are safe to trash: copies of a file that is kept.
    func confirmedExtras() async -> [URL] {
        await verifyAll()
        // If checking was stopped part-way, only fully checked sets are trashed.
        return groups.filter(\.verified).flatMap { g in g.files.map(\.url).filter { !(keep[g.id] ?? []).contains($0) } }
    }

    func didTrash(_ urls: [URL]) {
        let gone = Set(urls)
        trashedCount += urls.count
        groups = groups.compactMap { g in
            var g = g
            g.files.removeAll { gone.contains($0.url) }
            return g.files.count > 1 ? g : nil
        }
    }
}

final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = false
    var value: Bool {
        get { lock.withLock { _value } }
        set { lock.withLock { _value = newValue } }
    }
}

struct DuplicatesWindow: View {
    let url: URL
    @ViewState private var dupes: DuplicatesModel

    init(url: URL) {
        self.url = url
        _dupes = ViewState(initialValue: DuplicatesModel(folder: url))
    }

    var body: some View {
        DuplicatesView(dupes: dupes)
            .frame(minWidth: 820, minHeight: 560)
            .onAppear { if dupes.phase == .idle { dupes.scan() } }
            .onDisappear { dupes.stop() }
            .navigationTitle("Duplicates — \(url.path == "/" ? "/" : url.lastPathComponent)")
    }
}

struct DuplicatesView: View {
    @Bindable var dupes: DuplicatesModel
    @Environment(AppModel.self) private var model
    @Environment(\.displayScale) private var displayScale
    @ViewState private var pendingTrash: [URL]?
    @ViewState private var preparing = false
    @AppStorage("duplicates.thumbnailSize") private var thumbSide: Double = 132

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            nextSteps
        }
        .confirmationDialog(trashTitle, isPresented: Binding(get: { pendingTrash != nil }, set: { if !$0 { pendingTrash = nil } })) {
            Button("Move to Trash", role: .destructive) {
                if let urls = pendingTrash {
                    model.trash(urls)
                    dupes.didTrash(urls)
                }
                pendingTrash = nil
            }
            Button("Cancel", role: .cancel) { pendingTrash = nil }
        } message: {
            Text("Every byte was compared: each is an exact copy of a file you’re keeping. They go through the queue, so Undo can bring them back.")
        }
    }

    var trashTitle: String {
        let n = pendingTrash?.count ?? 0
        return "Move \(n) extra cop\(n == 1 ? "y" : "ies") to the Trash?"
    }

    // MARK: Header

    var header: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text(dupes.folder.lastPathComponent).font(.headline)
                Text(dupes.folder.path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            Toggle("Subfolders", isOn: $dupes.options.includeSubfolders).toggleStyle(.checkbox)
            Toggle("Hidden files", isOn: $dupes.options.includeHidden).toggleStyle(.checkbox)
            Picker("Ignore under", selection: $dupes.options.minimumSize) {
                Text("Nothing").tag(Int64(1))
                Text("1 KB").tag(Int64(1024))
                Text("100 KB").tag(Int64(100 << 10))
                Text("1 MB").tag(Int64(1 << 20))
                Text("100 MB").tag(Int64(100 << 20))
            }
            .fixedSize()
            Toggle("Compare every byte", isOn: $dupes.options.everyByte)
                .toggleStyle(.checkbox)
                .help("Slower on big files. Otherwise same-sized files are compared by samples of their contents, and checked fully before anything is trashed.")
            if dupes.isBusy {
                Button("Stop") { dupes.stop() }
            } else {
                Button(dupes.phase == .idle ? "Find Duplicates" : "Scan Again") { dupes.scan() }
                    .keyboardShortcut("r")
            }
        }
        .padding(12)
    }

    // MARK: Groups

    @ViewBuilder var content: some View {
        if dupes.phase == .scanning || (dupes.phase == .verifying && dupes.groups.isEmpty) {
            VStack(spacing: 10) {
                ProgressView()
                Text(dupes.status).foregroundStyle(.secondary).monospacedDigit()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if dupes.phase == .done && dupes.groups.isEmpty {
            ContentUnavailableView(dupes.trashedCount > 0 ? "No duplicates left" : "No duplicates found",
                                   systemImage: "checkmark.circle",
                                   description: Text(dupes.trashedCount > 0
                                                     ? "\(dupes.trashedCount) extra copies were sent to the Trash."
                                                     : "No two files in this folder have the same contents."))
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    summary
                    ForEach(dupes.groups) { group in
                        GroupRow(group: group, dupes: dupes, root: dupes.folder, scale: displayScale, side: CGFloat(thumbSide))
                    }
                }
                .padding(14)
            }
            .background(Color(nsColor: .textBackgroundColor))
        }
    }

    var summary: some View {
        let copies = dupes.groups.reduce(0) { $0 + $1.files.count }
        return HStack(alignment: .firstTextBaseline, spacing: 18) {
            stat("\(dupes.groups.count)", dupes.groups.count == 1 ? "set of duplicates" : "sets of duplicates")
            stat("\(copies)", "files involved")
            stat("\(dupes.extraFiles.count)", "extra copies")
            stat(Format.bytes(dupes.extraBytes), "could be freed")
            Spacer()
            if dupes.unverifiedCount > 0 {
                Label("\(dupes.unverifiedCount) matched on samples", systemImage: "questionmark.circle")
                    .font(.callout).foregroundStyle(.orange)
                    .help("Same size and the same bytes at the start, end and 16 places in between. Very likely identical; every byte is checked before trashing.")
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.08)))
    }

    func stat(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(value).font(.title2.weight(.semibold)).monospacedDigit()
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: Next steps

    var nextSteps: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Next steps").font(.subheadline.weight(.semibold))
                Text(stepsText).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            HStack(spacing: 4) {
                Image(systemName: "photo").font(.caption2).foregroundStyle(.secondary)
                Slider(value: $thumbSide, in: 80...360)
                    .controlSize(.mini)
                    .frame(width: 100)
                    .help("Thumbnail size")
                    .accessibilityLabel("Thumbnail size")
                Image(systemName: "photo").font(.callout).foregroundStyle(.secondary)
            }
            .disabled(dupes.groups.isEmpty)
            if dupes.isBusy && !dupes.groups.isEmpty {
                ProgressView().controlSize(.small)
                Text(dupes.status).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Picker("Keep:", selection: $dupes.rule) {
                ForEach(KeepRule.allCases) { Text($0.label).tag($0) }
            }
            .fixedSize()
            .disabled(dupes.groups.isEmpty)
            Button("Check Every Byte") { Task { await dupes.verifyAll() } }
                .disabled(dupes.isBusy || dupes.unverifiedCount == 0)
            Button {
                preparing = true
                Task {
                    let urls = await dupes.confirmedExtras()
                    preparing = false
                    if !urls.isEmpty { pendingTrash = urls }
                }
            } label: {
                Label("Trash \(dupes.extraFiles.count) Extra Cop\(dupes.extraFiles.count == 1 ? "y" : "ies")", systemImage: "trash")
            }
            .keyboardShortcut(.defaultAction)
            .disabled(dupes.isBusy || preparing || dupes.extraFiles.isEmpty)
        }
        .padding(12)
    }

    var stepsText: String {
        if dupes.groups.isEmpty { return "Scan a folder to see files that are copies of each other." }
        return "1. In each set, the copy marked Keep stays. Click a picture to keep it too, or ⌥-click to keep only it.  "
            + "2. Trash the extra copies: anything not yet checked byte for byte is checked first, and Undo can restore them."
    }
}

/// One set of duplicates: a row of previews, the one(s) to keep highlighted.
private struct GroupRow: View {
    let group: DuplicateGroup
    let dupes: DuplicatesModel
    let root: URL
    let scale: CGFloat
    let side: CGFloat

    var kept: Set<URL> { dupes.keep[group.id] ?? [] }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("\(group.files.count) copies of “\((group.files.first { kept.contains($0.url) } ?? group.files[0]).name)”").font(.headline).lineLimit(1).truncationMode(.middle)
                Text("· \(Format.bytes(group.size)) each").foregroundStyle(.secondary)
                if group.verified {
                    Label("Identical", systemImage: "checkmark.seal.fill").foregroundStyle(.green).font(.caption)
                        .help("Every byte matches.")
                } else {
                    Label("Very likely identical", systemImage: "questionmark.circle").foregroundStyle(.orange).font(.caption)
                        .help("Matched on size and samples of the contents. Checked fully before trashing.")
                }
                Spacer()
                if kept.count < group.files.count {
                    Button("Keep All") { dupes.keepAll(group) }.buttonStyle(.link).font(.caption)
                        .help("Leave this set alone")
                } else {
                    Text("Left alone").font(.caption).foregroundStyle(.secondary)
                }
            }
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 12) {
                    ForEach(group.files) { file in
                        DuplicateCard(file: file, root: root, kept: kept.contains(file.url), scale: scale, side: side)
                            .onTapGesture {
                                if NSEvent.modifierFlags.contains(.option) { dupes.keepOnly(file, in: group) } else { dupes.toggleKeep(file, in: group) }
                            }
                            .contextMenu {
                                Button("Keep Only This") { dupes.keepOnly(file, in: group) }
                                Button("Quick Look") { QuickLook.shared.show(group.files.map(\.url)) }
                                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([file.url]) }
                            }
                    }
                }
                .padding(.bottom, 4)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.secondary.opacity(0.25)))
    }
}

private struct DuplicateCard: View {
    let file: DuplicateFile
    let root: URL
    let kept: Bool
    let scale: CGFloat
    let side: CGFloat
    @ViewState private var image: NSImage?

    var folderText: String {
        let parent = file.url.deletingLastPathComponent().standardizedFileURL.path
        let base = root.standardizedFileURL.path
        if parent == base { return "Top folder" }
        if parent.hasPrefix(base + "/") { return String(parent.dropFirst(base.count + 1)) }
        return parent
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ZStack(alignment: .topLeading) {
                Group {
                    if let image {
                        Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                    } else {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: file.url.path)).resizable().aspectRatio(contentMode: .fit)
                            .padding(side * 0.15)
                    }
                }
                .frame(width: side, height: side)
                .opacity(kept ? 1 : 0.55)
                Text(kept ? "Keep" : "Extra")
                    .font(.caption2.weight(.bold))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill(kept ? Color.green : Color.secondary.opacity(0.7)))
                    .foregroundStyle(.white)
                    .padding(4)
            }
            .padding(4)
            .background(RoundedRectangle(cornerRadius: 8).fill(kept ? Color.green.opacity(0.12) : .clear))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(kept ? Color.green : Color.secondary.opacity(0.2), lineWidth: kept ? 2 : 1))

            Text(file.name).font(.callout).lineLimit(1).truncationMode(.middle)
            Label(folderText, systemImage: "folder").font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
            if let date = file.created ?? file.modified {
                Text(Format.date(date)).font(.caption2).foregroundStyle(.secondary)
            }
        }
        .frame(width: side + 8)
        .help(file.url.path)
        .contentShape(Rectangle())
        .task(id: "\(file.url.path)|\(ThumbnailCache.bucket(for: side))") {
            if let cached = ThumbnailCache.shared.cached(file.url, side: side) { image = cached; return }
            image = await ThumbnailCache.shared.thumbnail(for: file.url, side: side, scale: scale)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(file.name), in \(folderText)")
        .accessibilityValue(kept ? "Kept" : "Extra copy")
        .accessibilityAddTraits(.isButton)
    }
}
