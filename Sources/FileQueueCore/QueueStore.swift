import Foundation

public protocol QueueStore: Sendable {
    func load() throws -> [Job]
    func save(_ jobs: [Job]) throws
}

/// Saves the queue as JSON, by default in ~/Library/Application Support/FileQueue/queue.json.
public struct JSONQueueStore: QueueStore {
    public let url: URL

    public init(url: URL = JSONQueueStore.defaultURL) {
        self.url = url
    }

    public static var defaultURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("FileQueue/queue.json")
    }

    /// If the saved file can't be read (corrupt, or from an incompatible version), it is moved
    /// aside as `queue.unreadable-<timestamp>.json` rather than silently overwritten later.
    public func load() throws -> [Job] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        do {
            return try JSONDecoder().decode([Job].self, from: Data(contentsOf: url))
        } catch {
            let stamp = Int(Date().timeIntervalSince1970)
            let aside = url.deletingLastPathComponent().appendingPathComponent("queue.unreadable-\(stamp).json")
            try? FileManager.default.moveItem(at: url, to: aside)
            throw error
        }
    }

    public func save(_ jobs: [Job]) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(jobs).write(to: url, options: .atomic)
    }
}
