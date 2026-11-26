import AppKit
import FileQueueCore
import Observation
import SwiftUI

/// Scans a folder in the background and keeps track of where you are in the map.
@MainActor
@Observable
final class DiskMapModel {
    let rootURL: URL
    private(set) var root: UsageNode?
    var focus: UsageNode?
    var selected: UsageNode?
    var hovered: UsageNode?
    private(set) var scannedFiles = 0
    private(set) var scannedBytes: Int64 = 0
    private(set) var isScanning = false
    @ObservationIgnored private var task: Task<Void, Never>?
    /// Lets the background scan stop early (rescan, or the window closing).
    @ObservationIgnored private var control: JobControl?

    init(rootURL: URL) {
        self.rootURL = rootURL
        scan()
    }

    func scan() {
        stop()
        isScanning = true
        scannedFiles = 0
        scannedBytes = 0
        let url = rootURL
        let control = JobControl()
        self.control = control
        let report: @Sendable (DiskUsageScanner.Progress) -> Void = { [weak self] p in
            Task { @MainActor in
                self?.scannedFiles = p.files
                self?.scannedBytes = p.bytes
            }
        }
        task = Task { [weak self] in
            let node = await Task.detached(priority: .userInitiated) {
                DiskUsageScanner.scan(url, progress: report, isCancelled: { control.isCancelled })
            }.value
            guard let self, !Task.isCancelled, !control.isCancelled else { return }
            // Keep the place in the map when rescanning, if that folder still exists.
            let previousPath = self.focus?.path.dropFirst().map(\.name) ?? []
            self.root = node
            var focus = node
            for name in previousPath {
                guard let next = focus.children.first(where: { $0.name == name && $0.canOpen }) else { break }
                focus = next
            }
            self.focus = focus
            self.selected = nil
            self.isScanning = false
            self.scannedFiles = node.fileCount
            self.scannedBytes = node.size
        }
    }

    func stop() {
        control?.cancel()
        task?.cancel()
    }

    func open(_ node: UsageNode) {
        if node.canOpen {
            focus = node
            selected = nil
        } else {
            selected = node
        }
    }

    func goUp() {
        if let parent = focus?.parent {
            selected = focus
            focus = parent
        }
    }
}

struct DiskMapWindow: View {
    let url: URL
    @ViewState private var map: DiskMapModel

    init(url: URL) {
        self.url = url
        _map = ViewState(initialValue: DiskMapModel(rootURL: url))
    }

    var body: some View {
        DiskMapView(map: map)
            .frame(minWidth: 900, minHeight: 560)
            .onDisappear { map.stop() }
            .navigationTitle("Disk Map — \(url.path == "/" ? "/" : url.lastPathComponent)")
    }
}

struct DiskMapView: View {
    let map: DiskMapModel
    @Environment(AppModel.self) private var model
    @ViewState private var confirmTrash: UsageNode?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HSplitView {
                ZStack {
                    if let focus = map.focus {
                        TreemapCanvas(map: map, focus: focus)
                    } else {
                        VStack(spacing: 10) {
                            ProgressView()
                            Text("Measuring… \(map.scannedFiles) files, \(Format.bytes(map.scannedBytes))")
                                .foregroundStyle(.secondary).monospacedDigit()
                        }
                    }
                }
                .frame(minWidth: 520)
                sidebar.frame(minWidth: 260, idealWidth: 300, maxWidth: 380)
            }
            Divider()
            infoBar
        }
        .confirmationDialog("Move “\(confirmTrash?.name ?? "")” to the Trash?", isPresented: Binding(
            get: { confirmTrash != nil }, set: { if !$0 { confirmTrash = nil } }
        )) {
            Button("Move to Trash (\(Format.bytes(confirmTrash?.size ?? 0)))", role: .destructive) {
                if let url = confirmTrash?.url { model.trash([url]) }
                confirmTrash = nil
            }
        } message: {
            Text("It goes through the queue and can be undone. Rescan the map afterwards to see the change.")
        }
    }

    // MARK: Header

    var header: some View {
        HStack(spacing: 6) {
            Button { map.goUp() } label: { Label("Up", systemImage: "arrow.up").labelStyle(.iconOnly) }
                .disabled(map.focus?.parent == nil)
                .help("Up one level")
            ForEach(map.focus?.path ?? [], id: \.id) { node in
                if node !== map.focus?.path.first { Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary) }
                Button(node.name) { map.focus = node; map.selected = nil }
                    .buttonStyle(.link)
                    .lineLimit(1)
            }
            Spacer()
            if map.isScanning {
                ProgressView().controlSize(.small)
                Text("\(map.scannedFiles) files · \(Format.bytes(map.scannedBytes))").font(.caption).foregroundStyle(.secondary).monospacedDigit()
            } else if let focus = map.focus {
                Text("\(Format.bytes(focus.size)) · \(focus.fileCount) files").font(.callout).foregroundStyle(.secondary)
            }
            Button { map.scan() } label: { Label("Rescan", systemImage: "arrow.clockwise") }
                .disabled(map.isScanning)
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    // MARK: Sidebar: largest items & legend

    var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Largest in “\(map.focus?.name ?? "")”").font(.headline).padding(10)
            List(selection: Binding(get: { map.selected?.id }, set: { id in
                map.selected = map.focus?.children.first { $0.id == id }
            })) {
                ForEach(map.focus?.children ?? [], id: \.id) { node in
                    HStack(spacing: 8) {
                        RoundedRectangle(cornerRadius: 2).fill(TreemapColors.color(node, index: 0)).frame(width: 10, height: 10)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(node.name).lineLimit(1).truncationMode(.middle)
                                if node.unreadable { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).help("Couldn’t be fully read") }
                            }
                            ProgressView(value: Double(node.size), total: Double(max(1, map.focus?.size ?? 1)))
                                .tint(TreemapColors.color(node, index: 0))
                        }
                        Text(Format.bytes(node.size)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    .tag(node.id)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { map.open(node) }
                }
            }
            .listStyle(.inset)
            Divider()
            legend.padding(10)
        }
    }

    var legend: some View {
        let kinds: [UsageNode.Kind] = [.folder, .image, .video, .audio, .document, .archive, .app, .other]
        return LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), alignment: .leading)], alignment: .leading, spacing: 4) {
            ForEach(kinds, id: \.self) { kind in
                HStack(spacing: 5) {
                    RoundedRectangle(cornerRadius: 2).fill(TreemapColors.base(kind)).frame(width: 10, height: 10)
                    Text(kind.label).font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: Info bar (hovered or selected item, with actions)

    var infoBar: some View {
        let node = map.hovered ?? map.selected
        return HStack(spacing: 10) {
            if let node {
                Image(systemName: node.isFolder ? "folder.fill" : node.kind == .group ? "square.grid.3x3" : "doc.fill")
                    .foregroundStyle(TreemapColors.color(node, index: 0))
                VStack(alignment: .leading, spacing: 1) {
                    Text(node.path.dropFirst().map(\.name).joined(separator: " / ").nonEmpty ?? node.name)
                        .lineLimit(1).truncationMode(.middle)
                    Text(details(node)).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if let selected = map.selected, selected === node {
                    actions(for: selected)
                }
            } else {
                Text("Hover over a block for details · click to select · double-click a folder to open it")
                    .foregroundStyle(.secondary)
                Spacer()
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .frame(minHeight: 44)
    }

    func details(_ node: UsageNode) -> String {
        var parts = [Format.bytes(node.size)]
        if let focus = map.focus, focus.size > 0 {
            parts.append(String(format: "%.1f%% of %@", Double(node.size) / Double(focus.size) * 100, focus.name))
        }
        if node.isFolder || node.kind == .group { parts.append("\(node.fileCount) files") }
        if node.unreadable { parts.append("some contents couldn’t be read") }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder func actions(for node: UsageNode) -> some View {
        if node.canOpen {
            Button("Open") { map.open(node) }
        }
        if let url = node.url {
            Button("Show in Source Pane") {
                model.activeSide = .source
                model.source.reveal([url])
            }
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            Button("Move to Trash…", role: .destructive) { confirmTrash = node }
        }
    }
}

// MARK: - Canvas

/// Draws the focused folder as a treemap: its items, and inside each big folder, that folder's items.
struct TreemapCanvas: View {
    let map: DiskMapModel
    let focus: UsageNode

    struct Tile {
        let node: UsageNode
        let rect: CGRect
        let depth: Int
        let color: Color
    }

    var body: some View {
        GeometryReader { geo in
            let tiles = layout(in: CGRect(origin: .zero, size: geo.size).insetBy(dx: 4, dy: 4))
            Canvas { context, _ in
                for tile in tiles {
                    let path = Path(roundedRect: tile.rect.insetBy(dx: 0.5, dy: 0.5), cornerRadius: tile.depth == 0 ? 3 : 2)
                    let highlighted = tile.node === map.hovered || tile.node === map.selected
                    context.fill(path, with: .color(tile.color.opacity(highlighted ? 1 : (tile.depth == 0 && tile.node.canOpen ? 0.55 : 0.85))))
                    context.stroke(path, with: .color(.black.opacity(0.25)), lineWidth: tile.node === map.selected ? 2.5 : 0.5)
                    if tile.node === map.selected {
                        context.stroke(path, with: .color(.white), lineWidth: 1.5)
                    }
                    // Label when there's room: folders at the top, files centered.
                    if tile.depth == 0, tile.rect.width > 56, tile.rect.height > 18 {
                        let text = Text("\(tile.node.name)  \(Format.bytes(tile.node.size))")
                            .font(.system(size: 11, weight: tile.node.isFolder ? .semibold : .regular))
                            .foregroundStyle(.white)
                        var label = context.resolve(text)
                        label.shading = .color(.white)
                        let point = tile.node.canOpen
                            ? CGPoint(x: tile.rect.minX + 5, y: tile.rect.minY + 3)
                            : CGPoint(x: tile.rect.midX, y: tile.rect.midY)
                        context.drawLayer { layer in
                            layer.clip(to: Path(tile.rect.insetBy(dx: 3, dy: 1)))
                            layer.draw(label, at: point, anchor: tile.node.canOpen ? .topLeading : .center)
                        }
                    }
                }
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case let .active(point): map.hovered = hit(point, tiles)?.node
                case .ended: map.hovered = nil
                }
            }
            .gesture(SpatialTapGesture(count: 2).onEnded { value in
                if let tile = hit(value.location, tiles) {
                    // Double-click: open the clicked folder (or the folder containing the clicked item).
                    let target = tile.node.canOpen ? tile.node : (tile.depth == 1 ? tile.node.parent : nil)
                    if let target { map.open(target) }
                }
            })
            .simultaneousGesture(SpatialTapGesture(count: 1).onEnded { value in
                map.selected = hit(value.location, tiles)?.node
            })
            .accessibilityElement()
            .accessibilityLabel("Disk map of \(focus.name), \(Format.bytes(focus.size))")
        }
    }

    /// Deepest tile under the point.
    func hit(_ point: CGPoint, _ tiles: [Tile]) -> Tile? {
        tiles.last { $0.rect.contains(point) }
    }

    func layout(in bounds: CGRect) -> [Tile] {
        var tiles: [Tile] = []
        let children = focus.children
        let rects = Treemap.layout(children.map { Double($0.size) }, in: bounds)
        for (index, (child, rect)) in zip(children, rects).enumerated() where rect.width >= 1 && rect.height >= 1 {
            let color = TreemapColors.color(child, index: index)
            tiles.append(Tile(node: child, rect: rect, depth: 0, color: color))
            // One level deeper for folders big enough to show it (leave a strip for the folder's label).
            guard child.canOpen, rect.width > 40, rect.height > 40 else { continue }
            let inner = CGRect(x: rect.minX + 3, y: rect.minY + 18, width: rect.width - 6, height: rect.height - 21)
            guard inner.width > 10, inner.height > 10 else { continue }
            let subRects = Treemap.layout(child.children.map { Double($0.size) }, in: inner)
            for (sub, subRect) in zip(child.children, subRects) where subRect.width >= 2 && subRect.height >= 2 {
                tiles.append(Tile(node: sub, rect: subRect, depth: 1,
                                  color: sub.isFolder ? color.opacity(0.9) : TreemapColors.color(sub, index: index)))
            }
        }
        return tiles
    }
}

enum TreemapColors {
    static func base(_ kind: UsageNode.Kind) -> Color {
        switch kind {
        case .folder: Color(hue: 0.58, saturation: 0.45, brightness: 0.70)
        case .image: Color(hue: 0.36, saturation: 0.55, brightness: 0.70)
        case .video: Color(hue: 0.78, saturation: 0.50, brightness: 0.72)
        case .audio: Color(hue: 0.08, saturation: 0.65, brightness: 0.85)
        case .document: Color(hue: 0.55, saturation: 0.65, brightness: 0.80)
        case .archive: Color(hue: 0.13, saturation: 0.55, brightness: 0.70)
        case .app: Color(hue: 0.98, saturation: 0.55, brightness: 0.78)
        case .other: Color(white: 0.55)
        case .group: Color(white: 0.42)
        }
    }

    /// Top-level folders get distinct hues so neighbours are easy to tell apart.
    static func color(_ node: UsageNode, index: Int) -> Color {
        guard node.isFolder else { return base(node.kind) }
        let hue = (0.58 + Double(index) * 0.618_034).truncatingRemainder(dividingBy: 1)
        return Color(hue: hue, saturation: 0.35, brightness: 0.62)
    }
}

extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
