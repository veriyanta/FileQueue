import AppKit
import FileQueueCore
import QuickLookThumbnailing
import Quartz
import SwiftUI

// MARK: - Thumbnails

/// Makes real previews (photos, video frames, PDFs, documents…) with Quick Look, and remembers them.
/// Thumbnails are made at a few fixed sizes so changing the slider reuses what's already made.
final class ThumbnailCache: @unchecked Sendable {
    static let shared = ThumbnailCache()
    private let cache: NSCache<NSString, NSImage> = {
        let c = NSCache<NSString, NSImage>()
        c.countLimit = 3000
        return c
    }()

    /// Files we tried and couldn't get a picture from (keyed like the cache, so an edited file is retried).
    private var noFrame: Set<NSString> = []
    private let lock = NSLock()
    private func hasNoFrame(_ k: NSString) -> Bool { lock.withLock { noFrame.contains(k) } }
    private func markNoFrame(_ k: NSString) { _ = lock.withLock { noFrame.insert(k) } }

    static func bucket(for side: CGFloat) -> CGFloat {
        [128, 256, 512].first { $0 >= side } ?? 512
    }

    private func key(_ url: URL, _ bucket: CGFloat) -> NSString {
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate?.timeIntervalSince1970 ?? 0
        return "\(url.path)|\(Int(bucket))|\(modified)" as NSString
    }

    func cached(_ url: URL, side: CGFloat) -> NSImage? {
        cache.object(forKey: key(url, Self.bucket(for: side)))
    }

    /// A preview of the file's contents, or nil if Quick Look can't make one (the icon is shown instead).
    func thumbnail(for url: URL, side: CGFloat, scale: CGFloat) async -> NSImage? {
        let bucket = Self.bucket(for: side)
        let k = key(url, bucket)
        if let hit = cache.object(forKey: k) { return hit }
        let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: bucket, height: bucket),
                                                   scale: scale, representationTypes: .thumbnail)
        if let rep = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request) {
            cache.setObject(rep.nsImage, forKey: k)
            return rep.nsImage
        }
        // Quick Look can't open MKV/WebM or most AVIs: pull a frame out ourselves and decode it.
        // If that fails too and ffmpeg is installed, ask ffmpeg (XviD ASP, CineForm, WMV, FLV…).
        let builtIn: (@Sendable (URL) -> CGImage?)? = switch url.pathExtension.lowercased() {
        case "mkv", "webm", "mk3d": { MatroskaFrame.image(at: $0) }
        case "avi", "divx": { AVIFrame.image(at: $0) }
        default: nil
        }
        let ffmpeg = MetadataReader.kind(of: url) == .video ? FFmpegFrame.executable : nil
        // Remembered failures are per "is ffmpeg installed", so installing it gets them retried.
        let failKey = "\(k)|\(ffmpeg?.path ?? "")" as NSString
        guard builtIn != nil || ffmpeg != nil, !hasNoFrame(failKey) else { return nil }
        let pixels = bucket * scale
        var frame = await Task.detached(priority: .utility) { () -> CGImage? in
            builtIn?(url).map { Self.scaled($0, toFit: pixels) }
        }.value
        if frame == nil, let ffmpeg {
            let duration = await MetadataReader.read(url).duration
            frame = await FFmpegFrame.image(at: url, duration: duration, maxSide: Int(pixels), executable: ffmpeg)
        }
        guard let frame else {
            markNoFrame(failKey) // don't read the file again on every scroll
            return nil
        }
        let image = NSImage(cgImage: frame, size: NSSize(width: CGFloat(frame.width) / scale, height: CGFloat(frame.height) / scale))
        cache.setObject(image, forKey: k)
        return image
    }

    /// Shrinks a decoded frame so a grid of 4K videos doesn't hold gigabytes of pixels.
    static func scaled(_ image: CGImage, toFit side: CGFloat) -> CGImage {
        let ratio = min(1, side / CGFloat(max(image.width, image.height)))
        guard ratio < 1 else { return image }
        let w = max(1, Int(CGFloat(image.width) * ratio)), h = max(1, Int(CGFloat(image.height) * ratio))
        guard let context = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return image }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return context.makeImage() ?? image
    }
}

// MARK: - Quick Look panel

/// Space bar: the full-size Quick Look panel for the selected items, as in Finder.
@MainActor
final class QuickLook: NSObject, @preconcurrency QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    static let shared = QuickLook()
    private var urls: [URL] = []

    func toggle(_ urls: [URL]) {
        guard let panel = QLPreviewPanel.shared() else { return }
        if panel.isVisible {
            panel.orderOut(nil)
            return
        }
        show(urls)
    }

    func show(_ urls: [URL]) {
        guard !urls.isEmpty, let panel = QLPreviewPanel.shared() else { return }
        self.urls = urls
        panel.dataSource = self
        panel.delegate = self
        panel.reloadData()
        panel.currentPreviewItemIndex = 0
        panel.makeKeyAndOrderFront(nil)
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { urls.count }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        urls.indices.contains(index) ? urls[index] as NSURL : nil
    }
}

// MARK: - Grid

/// Finder-style icon view with big thumbnails: click to select (⌘ toggles, ⇧ extends), double-click to open,
/// drag to the other pane, right-click for actions, Space for Quick Look.
struct FolderGrid: View {
    @Bindable var pane: PaneModel
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @Environment(\.displayScale) private var displayScale
    /// Where a ⇧-click range starts.
    @ViewState private var anchor: Int?
    @FocusState private var focused: Bool

    var side: CGFloat { CGFloat(pane.thumbnailSize) }

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: side + 16, maximum: side + 40), spacing: 10, alignment: .top)],
                      alignment: .leading, spacing: 14) {
                ForEach(Array(pane.entries.enumerated()), id: \.element.id) { index, entry in
                    ThumbnailCell(entry: entry, side: side, scale: displayScale, selected: pane.selection.contains(entry.url))
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) { pane.activate([entry.url]) }
                        .simultaneousGesture(TapGesture().onEnded { click(entry, index) })
                        .onDrag {
                            model.draggedURLs = pane.selection.contains(entry.url) ? pane.selectedURLs : [entry.url]
                            return NSItemProvider(object: entry.url as NSURL)
                        }
                        .contextMenu { menu(for: entry) }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(nsColor: .textBackgroundColor))
        // A click on empty space clears the selection.
        .onTapGesture {
            pane.selection = []
            model.activeSide = pane.side
            focused = true
        }
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onKeyPress(.space) {
            QuickLook.shared.toggle(pane.selectedURLs)
            return .handled
        }
        .onKeyPress(.return) {
            pane.activate(pane.selection)
            return .handled
        }
        .onDeleteCommand { if !pane.selection.isEmpty && !pane.isReadOnly { model.confirmTrash = true } }
        .onCommand(#selector(NSResponder.selectAll(_:))) { pane.selectAll() }
        .contextMenu {
            Button("Select All") { model.activeSide = pane.side; pane.selectAll() }
                .disabled(pane.entries.isEmpty)
        }
        .overlay {
            if let error = pane.error {
                ContentUnavailableView("Can’t open this folder", systemImage: "lock", description: Text(error))
            } else if pane.entries.isEmpty {
                Text("Empty folder").foregroundStyle(.tertiary)
            }
        }
    }

    func click(_ entry: DirectoryEntry, _ index: Int) {
        focused = true
        model.activeSide = pane.side
        let flags = NSEvent.modifierFlags
        if flags.contains(.command) {
            if pane.selection.contains(entry.url) { pane.selection.remove(entry.url) } else { pane.selection.insert(entry.url) }
            anchor = index
        } else if flags.contains(.shift), let anchor, pane.entries.indices.contains(anchor) {
            let range = min(anchor, index)...max(anchor, index)
            pane.selection.formUnion(pane.entries[range].map(\.url))
        } else {
            pane.selection = [entry.url]
            anchor = index
        }
    }

    /// Right-click acts on the selection if the item is part of it, otherwise on just that item.
    @ViewBuilder func menu(for entry: DirectoryEntry) -> some View {
        let targets = pane.selection.contains(entry.url) ? pane.selectedURLs : [entry.url]
        let select = {
            model.activeSide = pane.side
            pane.selection = Set(targets)
        }
        Button("Quick Look") { select(); QuickLook.shared.show(targets) }
        Button("Open") { select(); pane.activate(Set(targets)) }
        Divider()
        Button(pane.side == .source ? "Copy to Destination" : "Copy to Source") { select(); model.transferSelection(move: false) }
        Button(pane.side == .source ? "Move to Destination" : "Move to Source") { select(); model.transferSelection(move: true) }
            .disabled(pane.isReadOnly)
        Divider()
        Button("Rename…") { select(); model.beginRename() }.disabled(pane.isReadOnly)
        Button("Batch Rename…") { select(); model.beginBatchRename() }.disabled(pane.isReadOnly)
        Button("Organize into Folders…") { select(); model.beginOrganize() }
        Button("Remove Empty Folders…") { select(); openWindow(id: "emptyfolders", value: model.diskMapTarget) }.disabled(pane.isReadOnly)
        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting(targets) }
        Divider()
        Button("Move to Trash") { select(); model.confirmTrash = true }.disabled(pane.isReadOnly)
    }
}

/// One item: a big preview (the icon until the preview is ready), its name, and size or kind.
struct ThumbnailCell: View {
    let entry: DirectoryEntry
    let side: CGFloat
    let scale: CGFloat
    let selected: Bool
    @ViewState private var image: NSImage?

    var isVideo: Bool { MetadataReader.kind(of: entry.url) == .video }

    var body: some View {
        VStack(spacing: 6) {
            ZStack(alignment: .bottomTrailing) {
                Group {
                    if let image {
                        Image(nsImage: image)
                            .resizable()
                            .interpolation(.high)
                            .aspectRatio(contentMode: .fit)
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                            .shadow(color: .black.opacity(0.18), radius: 2, y: 1)
                    } else {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: entry.url.path))
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .padding(side * 0.12)
                    }
                }
                .frame(width: side, height: side)
                if isVideo, image != nil {
                    Image(systemName: "play.circle.fill")
                        .font(.system(size: max(14, side * 0.12)))
                        .foregroundStyle(.white, .black.opacity(0.45))
                        .padding(6)
                        .accessibilityHidden(true)
                }
            }
            .padding(6)
            .background(RoundedRectangle(cornerRadius: 8).fill(selected ? Color.accentColor.opacity(0.18) : .clear))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 2))

            Text(entry.name)
                .font(.callout)
                .lineLimit(2)
                .truncationMode(.middle)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 4)
                .background(RoundedRectangle(cornerRadius: 4).fill(selected ? Color.accentColor : .clear))
                .foregroundStyle(selected ? Color.white : Color.primary)
                .frame(width: side + 12)
            Text(detail)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(width: side + 16)
        .task(id: "\(entry.url.path)|\(ThumbnailCache.bucket(for: side))") {
            if let cached = ThumbnailCache.shared.cached(entry.url, side: side) {
                image = cached
                return
            }
            image = await ThumbnailCache.shared.thumbnail(for: entry.url, side: side, scale: scale)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(entry.name)
        .accessibilityValue(detail)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    var detail: String {
        if entry.isFolder { return "Folder" }
        return entry.size.map(Format.bytes) ?? ""
    }
}
