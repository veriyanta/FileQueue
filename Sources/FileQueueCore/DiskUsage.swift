import CoreGraphics
import Foundation
import UniformTypeIdentifiers

/// One block in the disk map: a folder (with children), a file, or a group of small items.
public final class UsageNode: Identifiable, @unchecked Sendable {
    public enum Kind: String, Sendable, CaseIterable {
        case folder, image, video, audio, document, archive, app, other, group
        public var label: String {
            switch self {
            case .folder: "Folders"
            case .image: "Photos"
            case .video: "Videos"
            case .audio: "Audio"
            case .document: "Documents"
            case .archive: "Archives & disk images"
            case .app: "Apps"
            case .other: "Other files"
            case .group: "Smaller items"
            }
        }
    }

    public let id = UUID()
    public let name: String
    /// nil for a group of smaller items.
    public let url: URL?
    public let kind: Kind
    /// Space used on disk (allocated size), including everything inside.
    public internal(set) var size: Int64 = 0
    public internal(set) var fileCount = 0
    /// Largest first.
    public internal(set) var children: [UsageNode] = []
    /// The folder (or part of it) couldn't be read.
    public internal(set) var unreadable = false
    public internal(set) weak var parent: UsageNode?

    init(name: String, url: URL?, kind: Kind) {
        self.name = name
        self.url = url
        self.kind = kind
    }

    public var isFolder: Bool { kind == .folder }
    public var canOpen: Bool { isFolder && !children.isEmpty }

    /// From the root down to this node.
    public var path: [UsageNode] {
        var nodes: [UsageNode] = [self]
        while let p = nodes.last?.parent { nodes.append(p) }
        return nodes.reversed()
    }

    static func kind(for url: URL, isDirectory: Bool, isPackage: Bool) -> Kind {
        if isPackage { return url.pathExtension.lowercased() == "app" ? .app : .other }
        if isDirectory { return .folder }
        guard let type = UTType(filenameExtension: url.pathExtension) else { return .other }
        if type.conforms(to: .image) { return .image }
        if type.conforms(to: .movie) || type.conforms(to: .video) { return .video }
        if type.conforms(to: .audio) { return .audio }
        if type.conforms(to: .archive) || type.conforms(to: .diskImage) { return .archive }
        if type.conforms(to: .application) || type.conforms(to: .applicationBundle) { return .app }
        if type.conforms(to: .text) || type.conforms(to: .pdf) || type.conforms(to: .presentation)
            || type.conforms(to: .spreadsheet) || type.conforms(to: .compositeContent) { return .document }
        return .other
    }
}

public enum DiskUsageScanner {
    public struct Progress: Sendable {
        public var files: Int
        public var bytes: Int64
    }

    /// Measures `root` and everything inside it. Other disks mounted inside it aren't counted.
    /// Each folder keeps its `maxChildren` largest items; the rest become one "smaller items" block.
    public static func scan(
        _ root: URL, maxChildren: Int = 250,
        progress: (@Sendable (Progress) -> Void)? = nil,
        isCancelled: @Sendable () -> Bool = { false }
    ) -> UsageNode {
        let node = UsageNode(name: displayName(root), url: root, kind: .folder)
        var counter = Progress(files: 0, bytes: 0)
        fill(node, at: root, isRoot: true, maxChildren: maxChildren, counter: &counter, progress: progress, isCancelled: isCancelled)
        progress?(counter)
        return node
    }

    static let keys: [URLResourceKey] = [
        .isDirectoryKey, .isPackageKey, .isSymbolicLinkKey, .isVolumeKey,
        .totalFileAllocatedSizeKey, .fileAllocatedSizeKey,
    ]

    static func fill(
        _ node: UsageNode, at url: URL, isRoot: Bool, maxChildren: Int, counter: inout Progress,
        progress: (@Sendable (Progress) -> Void)?, isCancelled: @Sendable () -> Bool
    ) {
        guard !isCancelled() else { return }
        let contents: [URL]
        do {
            contents = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: keys, options: [])
        } catch {
            node.unreadable = true
            return
        }
        var children: [UsageNode] = []
        for item in contents {
            guard let v = try? item.resourceValues(forKeys: Set(keys)) else { continue }
            if v.isSymbolicLink == true {
                continue // links take no real space and may point anywhere
            }
            let isDir = v.isDirectory == true
            if isDir {
                // Another disk mounted inside this folder (or an APFS system/data volume): not part of this folder.
                if v.isVolume == true { continue }
                let child = UsageNode(name: item.lastPathComponent, url: item,
                                      kind: UsageNode.kind(for: item, isDirectory: true, isPackage: v.isPackage == true))
                fill(child, at: item, isRoot: false, maxChildren: maxChildren, counter: &counter, progress: progress, isCancelled: isCancelled)
                if child.kind != .folder { child.children = [] } // packages are shown as one block
                child.parent = node
                children.append(child)
            } else {
                let size = Int64(v.totalFileAllocatedSize ?? v.fileAllocatedSize ?? 0)
                let child = UsageNode(name: item.lastPathComponent, url: item,
                                      kind: UsageNode.kind(for: item, isDirectory: false, isPackage: false))
                child.size = size
                child.fileCount = 1
                child.parent = node
                children.append(child)
                counter.files += 1
                counter.bytes += size
                if counter.files % 2000 == 0 { progress?(counter) }
            }
            if isCancelled() { return }
        }
        children.sort { $0.size > $1.size }
        if children.count > maxChildren {
            let kept = Array(children.prefix(maxChildren - 1))
            let rest = children.dropFirst(maxChildren - 1)
            let group = UsageNode(name: "\(rest.count) smaller items", url: nil, kind: .group)
            group.size = rest.reduce(0) { $0 + $1.size }
            group.fileCount = rest.reduce(0) { $0 + $1.fileCount }
            group.parent = node
            children = kept + [group]
        }
        node.children = children
        node.size = children.reduce(0) { $0 + $1.size }
        node.fileCount = children.reduce(0) { $0 + $1.fileCount }
        node.unreadable = node.unreadable || children.contains { $0.unreadable }
    }

    static func displayName(_ url: URL) -> String {
        url.path == "/" ? "/" : FileManager.default.displayName(atPath: url.path)
    }
}

/// Squarified treemap layout (Bruls, Huizing & van Wijk): rectangles proportional to `values`,
/// kept as close to square as possible so sizes are easy to compare.
public enum Treemap {
    /// `values` should be sorted largest first. Returns one rectangle per value (zero-size for values ≤ 0).
    public static func layout(_ values: [Double], in rect: CGRect) -> [CGRect] {
        var rects = [CGRect](repeating: .zero, count: values.count)
        let total = values.reduce(0) { $0 + max(0, $1) }
        guard total > 0, rect.width > 0, rect.height > 0 else { return rects }
        let scale = Double(rect.width * rect.height) / total
        let indices = values.indices.filter { values[$0] > 0 }
        let areas = indices.map { values[$0] * scale }

        var remaining = rect
        var i = 0
        while i < areas.count {
            let side = Double(min(remaining.width, remaining.height))
            var rowEnd = i + 1
            var rowSum = areas[i]
            var best = worst(areas[i..<rowEnd], rowSum, side)
            while rowEnd < areas.count {
                let candidateSum = rowSum + areas[rowEnd]
                let candidate = worst(areas[i...rowEnd], candidateSum, side)
                if candidate > best { break }
                rowSum = candidateSum
                best = candidate
                rowEnd += 1
            }
            if remaining.width >= remaining.height {
                // A column on the left.
                let width = rowSum / Double(remaining.height)
                var y = Double(remaining.minY)
                for k in i..<rowEnd {
                    let h = areas[k] / width
                    rects[indices[k]] = CGRect(x: Double(remaining.minX), y: y, width: width, height: h)
                    y += h
                }
                remaining = CGRect(x: remaining.minX + width, y: remaining.minY,
                                   width: max(0, remaining.width - width), height: remaining.height)
            } else {
                // A row along the top.
                let height = rowSum / Double(remaining.width)
                var x = Double(remaining.minX)
                for k in i..<rowEnd {
                    let w = areas[k] / height
                    rects[indices[k]] = CGRect(x: x, y: Double(remaining.minY), width: w, height: height)
                    x += w
                }
                remaining = CGRect(x: remaining.minX, y: remaining.minY + height,
                                   width: remaining.width, height: max(0, remaining.height - height))
            }
            i = rowEnd
        }
        return rects
    }

    /// The worst (largest) aspect ratio in a row with total area `sum` laid along a side of length `side`.
    static func worst(_ row: ArraySlice<Double>, _ sum: Double, _ side: Double) -> Double {
        let s2 = sum * sum, w2 = side * side
        return row.reduce(0) { max($0, max(w2 * $1 / s2, s2 / (w2 * $1))) }
    }
}
