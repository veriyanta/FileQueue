import FileQueueCore
import Observation
import SwiftUI

/// Lists the files to work on (optionally everything inside folders), then reads full details
/// (EXIF, video headers) for a **sample** — a few files from each folder — so suggestions and previews
/// appear quickly even for huge folders. The rest are read on request (`readAll`).
/// Everything heavy runs off the main thread; progress reaches the screen at most 5 times a second.
@MainActor
@Observable
final class MediaScan {
    enum Phase: Equatable { case listing, sampling, sampled, readingAll, complete }

    let inputs: [URL]
    let hasFolders: Bool
    var recursive: Bool {
        didSet { if recursive != oldValue { start() } }
    }

    private(set) var phase: Phase = .listing
    private(set) var files: [URL] = []
    /// Details for every file: full where read, otherwise just what the file system knows.
    private(set) var metadata: [URL: FileMetadata] = [:]
    /// Files whose full details haven't been read yet.
    private(set) var unread: Set<URL> = []
    private(set) var readCount = 0
    private(set) var sampleCount = 0
    /// Seconds left while reading everything (estimated).
    private(set) var secondsLeft: Double?
    private(set) var coverage: [MetadataSuggestions.Coverage] = []
    private(set) var renameSuggestions: [MetadataSuggestions.Suggestion] = []
    private(set) var organizeSuggestions: [MetadataSuggestions.Suggestion] = []
    /// What the files are, e.g. "212 photos, 38 videos".
    private(set) var summary = ""
    /// Bumped whenever files or details change, so views can recompute plans.
    private(set) var version = 0

    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var fullyRead: [URL: FileMetadata] = [:]

    init(inputs: [URL], recursive: Bool? = nil) {
        self.inputs = inputs
        hasFolders = inputs.contains { FS.isMergeableFolder($0) }
        self.recursive = recursive ?? hasFolders
        start()
    }

    func cancel() { task?.cancel() }

    var isBusy: Bool { phase == .listing || phase == .sampling || phase == .readingAll }
    var isComplete: Bool { phase == .complete }
    /// Files whose details are known in full.
    var totalRead: Int { files.count - unread.count }

    /// The photos and videos read so far (if any), otherwise everything read: suggestions are based on these.
    var mediaMetadata: [FileMetadata] {
        let read = Array(fullyRead.values)
        let media = read.filter { $0.kind == .image || $0.kind == .video }
        return media.isEmpty ? read : media
    }

    /// A photo/video whose details are known, to show what a suggested name looks like.
    /// Chosen once after the sample is read (never recomputed while redrawing).
    private(set) var sampleFile: URL?

    func example(_ template: String) -> String? {
        guard let url = sampleFile else { return nil }
        let ext = url.pathExtension
        let name = ext.isEmpty ? url.lastPathComponent : url.deletingPathExtension().lastPathComponent
        let r = NameTemplate.render(template, .init(metadata: metadata[url], name: name, ext: ext))
        return r.missing.isEmpty ? r.text : nil
    }

    /// List everything (with basic file-system info), then read a sample in full.
    private func start() {
        task?.cancel()
        phase = .listing
        fullyRead = [:]
        let inputs = self.inputs, recursive = self.recursive
        task = Task { [weak self] in
            let (files, basic) = await Task.detached(priority: .userInitiated) { () -> ([URL], [URL: FileMetadata]) in
                let files = FileExpander.expand(inputs, recursive: recursive)
                var basic: [URL: FileMetadata] = [:]
                basic.reserveCapacity(files.count)
                for url in files { basic[url] = MetadataReader.readBasic(url) }
                return (files, basic)
            }.value
            guard let self, !Task.isCancelled else { return }
            self.files = files
            self.metadata = basic
            self.unread = Set(files)
            self.readCount = 0
            await self.refreshSuggestions()

            // A few files from each folder first.
            let sample = MediaSampler.sample(files)
            self.sampleCount = sample.count
            self.sampleFile = files.first
            self.phase = .sampling
            await self.read(sample)
            guard !Task.isCancelled else { return }
            self.sampleFile = sample.first { self.metadata[$0].map { $0.kind == .image || $0.kind == .video } ?? false }
                ?? sample.first ?? files.first
            self.phase = self.unread.isEmpty ? .complete : .sampled
        }
    }

    /// Reads full details for every file not read yet. Returns when done or stopped.
    func readAll() async {
        guard !unread.isEmpty, phase != .readingAll else { return }
        task?.cancel()
        phase = .readingAll
        let remaining = files.filter { unread.contains($0) }
        let job = Task { [weak self] () -> Void in
            guard let self else { return }
            await self.read(remaining)
        }
        task = job
        await job.value
        if phase == .readingAll { phase = unread.isEmpty ? .complete : .sampled }
    }

    /// Stops reading; what was read so far is kept.
    func stopReading() {
        task?.cancel()
        if phase == .readingAll || phase == .sampling { phase = unread.isEmpty ? .complete : .sampled }
        secondsLeft = nil
    }

    /// Reads `urls` in batches off the main thread. The main thread only merges results and shows
    /// progress; suggestions and previews are recomputed in the background, at most every 3 seconds.
    private func read(_ urls: [URL]) async {
        let counter = ProgressCounter()
        let started = Date()
        let alreadyRead = totalRead
        // Progress is polled a few times a second rather than sent once per file.
        let ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(200))
                guard let self else { return }
                let done = counter.value
                self.readCount = alreadyRead + done
                let elapsed = Date().timeIntervalSince(started)
                if done > 20, elapsed > 1 {
                    self.secondsLeft = Double(urls.count - done) * elapsed / Double(done)
                }
            }
        }
        defer {
            ticker.cancel()
            secondsLeft = nil
        }
        let batch = 300
        var index = 0
        var lastRefresh = Date()
        while index < urls.count, !Task.isCancelled {
            let chunk = Array(urls[index..<min(urls.count, index + batch)])
            let part = await MetadataReader.readAll(chunk) { _ in counter.increment() }
            if Task.isCancelled { break }
            for (url, meta) in part {
                fullyRead[url] = meta
                metadata[url] = meta
                unread.remove(url)
            }
            readCount = totalRead
            index += batch
            if Date().timeIntervalSince(lastRefresh) > 3 {
                await refreshSuggestions()
                lastRefresh = Date()
            }
        }
        await refreshSuggestions()
    }

    /// Recomputes suggestions, coverage and the summary off the main thread, then publishes them.
    private func refreshSuggestions() async {
        let metas = mediaMetadata
        let kindsList = files.map { metadata[$0]?.kind ?? .other }
        let result = await Task.detached(priority: .userInitiated) {
            () -> ([MetadataSuggestions.Coverage], [MetadataSuggestions.Suggestion], [MetadataSuggestions.Suggestion], String) in
            let coverage = MetadataSuggestions.coverage(metas)
            let rename = MetadataSuggestions.renameSuggestions(metas)
            let organize = MetadataSuggestions.organizeSuggestions(metas)
            var kinds: [FileMetadata.Kind: Int] = [:]
            for k in kindsList { kinds[k, default: 0] += 1 }
            var parts: [String] = []
            if let n = kinds[.image] { parts.append("\(n) photo\(n == 1 ? "" : "s")") }
            if let n = kinds[.video] { parts.append("\(n) video\(n == 1 ? "" : "s")") }
            let others = (kinds[.audio] ?? 0) + (kinds[.other] ?? 0)
            if others > 0 { parts.append("\(others) other") }
            return (coverage, rename, organize, parts.joined(separator: ", "))
        }.value
        (coverage, renameSuggestions, organizeSuggestions, summary) = result
        version += 1
    }
}

/// A thread-safe counter for progress from background work.
final class ProgressCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}

// MARK: - Shared views

/// What's been read: "Details read for a sample of 240 of 12,431 · Read All Details".
struct ScanStatus: View {
    let scan: MediaScan
    /// Whether the current layout/rules need full details (otherwise reading more doesn't matter).
    var needsDetails = true

    var body: some View {
        HStack(spacing: 8) {
            switch scan.phase {
            case .listing:
                ProgressView().controlSize(.small)
                Text("Listing files…").foregroundStyle(.secondary)
            case .sampling:
                ProgressView().controlSize(.small)
                Text("Reading a sample (a few files from each folder)… \(scan.readCount) of \(scan.sampleCount)")
                    .foregroundStyle(.secondary).monospacedDigit()
            case .sampled:
                Text(filesText).foregroundStyle(.secondary)
                Text("· details read for a sample of \(scan.totalRead)")
                    .foregroundStyle(needsDetails ? .orange : .secondary)
                    .help("Suggestions are based on a few files from each folder. Read all details before moving or renaming by them.")
                Button("Read All Details") { Task { await scan.readAll() } }
                    .controlSize(.small)
            case .readingAll:
                ProgressView(value: Double(scan.readCount), total: Double(max(1, scan.files.count)))
                    .frame(width: 140)
                Text("Reading details… \(scan.readCount) of \(scan.files.count)" + eta)
                    .foregroundStyle(.secondary).monospacedDigit()
                Button("Stop") { scan.stopReading() }.controlSize(.small)
            case .complete:
                Text(filesText + " · all details read").foregroundStyle(.secondary)
            }
        }
        .font(.callout)
        .lineLimit(1)
        .truncationMode(.tail)
    }

    var filesText: String {
        "\(scan.files.count) file\(scan.files.count == 1 ? "" : "s")" + (scan.summary.isEmpty ? "" : " (\(scan.summary))")
    }

    var eta: String {
        guard let s = scan.secondsLeft, s > 2 else { return "" }
        return " · about \(Format.duration(s)) left"
    }
}

/// One-click suggestions based on what most of the files have in common.
struct SuggestionBar: View {
    let title: String
    let suggestions: [MetadataSuggestions.Suggestion]
    let scan: MediaScan
    let apply: (String) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Label(title, systemImage: "sparkles")
                .font(.callout.weight(.semibold))
                .padding(.top, 5)
            if suggestions.isEmpty {
                Text(scan.phase == .listing || scan.phase == .sampling ? "Looking at a few files from each folder…" : "No details shared by most of these files. Use the rules or fields below.")
                    .font(.callout).foregroundStyle(.secondary)
                    .padding(.top, 5)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(suggestions) { s in
                            Button { apply(s.template) } label: {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text("\(s.title) · \(Int((s.fraction * 100).rounded()))%")
                                        .font(.callout.weight(.medium))
                                    Text(scan.example(s.template).map { "e.g. \($0)" } ?? s.template)
                                        .font(.caption).foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                .padding(.horizontal, 10).padding(.vertical, 5)
                                .background(RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(0.10)))
                                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.accentColor.opacity(0.35)))
                            }
                            .buttonStyle(.plain)
                            .help("Use \(s.template) — works for \(Int((s.fraction * 100).rounded()))% of the photos/videos")
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

/// Which details the files have, and how many of them have each. Clicking one inserts its field.
struct CoverageList: View {
    let scan: MediaScan
    let insert: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(scan.isComplete ? "Details found" : "Details found (in the files read so far)")
                .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            if scan.coverage.isEmpty {
                Text(scan.phase == .listing || scan.phase == .sampling ? "Reading…" : "None").font(.caption).foregroundStyle(.tertiary)
            }
            ForEach(scan.coverage) { c in
                Button { insert(c.token) } label: {
                    HStack(spacing: 6) {
                        Text(c.label).font(.caption)
                        ProgressView(value: c.fraction).frame(width: 50)
                        Text("\(Int((c.fraction * 100).rounded()))%").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        if let ex = c.example {
                            Text(ex).font(.caption).foregroundStyle(.tertiary).lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Insert \(c.token)")
            }
        }
    }
}

/// "Insert field" menu listing every template field by group.
struct FieldMenu: View {
    /// Fields to leave out (e.g. titles in a folder layout, where they'd make a folder per file).
    var excluding: Set<String> = []
    let insert: (String) -> Void

    var fields: [NameTemplate.Field] { NameTemplate.fields.filter { !excluding.contains($0.token) } }

    var body: some View {
        Menu {
            ForEach(Array(Dictionary(grouping: fields, by: \.group).keys.sorted()), id: \.self) { group in
                Section(group) {
                    ForEach(fields.filter { $0.group == group }) { field in
                        Button("\(field.label)   \(field.token)") { insert(field.token) }
                    }
                }
            }
        } label: {
            Label("Insert Field", systemImage: "plus.square.on.square")
        }
        .fixedSize()
    }
}

/// Appends a field to a template with a space if needed.
func appending(_ token: String, to template: String) -> String {
    if template.isEmpty || template.hasSuffix(" ") || template.hasSuffix("/") { return template + token }
    return template + " " + token
}
