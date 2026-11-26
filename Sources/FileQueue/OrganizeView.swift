import FileQueueCore
import SwiftUI

/// Sorts files into folders by date, camera, type, or parts of their names.
struct OrganizeView: View {
    let request: OrganizeRequest
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @ViewState private var scan: MediaScan
    @ViewState private var template = "{taken:yyyy}/{taken:MM}"
    @ViewState private var namePattern = ""
    /// Optional new file name, e.g. "{title:clean}" (empty keeps names).
    @ViewState private var nameTemplate = ""
    @ViewState private var fallback = "Unsorted"
    @ViewState private var move = true
    @ViewState private var intoOtherPane = false
    @ViewState private var removeEmpty = true
    @ViewState private var plan = OrganizePlanner.Plan(items: [], error: nil)
    /// Counts and folder list, worked out once per plan (not on every redraw).
    @ViewState private var summary = OrganizeSummary()
    @ViewState private var planTask: Task<Void, Never>?
    /// Set while the job is being handed to the queue (the window stays open until it's there).
    @ViewState private var handoff: Handoff?
    @ViewState private var handoffStarted = Date()
    @ViewState private var handoffError: String?
    /// The plan that clashed with a queued job, ready for "Add Anyway".
    @ViewState private var overlappingPlan: OrganizePlanner.Plan?
    /// Folders never get more than this many files; beyond it, numbered subfolders 001, 002…
    @AppStorage("organizeMaxPerFolder") private var maxPerFolder = 4096
    @ViewState private var selectedFolder: String?

    init(request: OrganizeRequest) {
        self.request = request
        _scan = ViewState(initialValue: MediaScan(inputs: request.inputs, recursive: true))
    }

    /// Where the new folders are created.
    var root: URL { intoOtherPane ? request.otherFolder : request.root }
    var needsDetails: Bool { NameTemplate.needsDetails(template) || NameTemplate.needsDetails(nameTemplate) }
    /// Some files have a title stored inside them.
    var titlesFound: Bool { scan.coverage.contains { $0.label == "Title" } }
    /// The layout needs details that haven't been read for every file yet.
    var waitingForDetails: Bool { needsDetails && !scan.unread.isEmpty }

    var body: some View {
        @Bindable var scan = scan
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                ScanStatus(scan: scan, needsDetails: needsDetails)
                if scan.hasFolders {
                    Toggle("Include files in subfolders", isOn: $scan.recursive).toggleStyle(.checkbox)
                }
                Spacer()
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            Divider()
            SuggestionBar(title: "Suggested layouts", suggestions: scan.organizeSuggestions, scan: scan) { template = $0 }
            Divider()
            HSplitView {
                settings.frame(minWidth: 360, idealWidth: 420, maxWidth: 520)
                preview.frame(minWidth: 480)
            }
            Divider()
            footer
        }
        .frame(minWidth: 1020, idealWidth: 1120, maxWidth: 1500, minHeight: 640, idealHeight: 760)
        .onAppear(perform: schedulePlan)
        .onChange(of: template) { schedulePlan() }
        .onChange(of: namePattern) { schedulePlan() }
        .onChange(of: nameTemplate) { schedulePlan() }
        .onChange(of: fallback) { schedulePlan() }
        .onChange(of: maxPerFolder) { schedulePlan() }
        .onChange(of: intoOtherPane) { schedulePlan() }
        .onChange(of: scan.version) { schedulePlan() }
    }

    // MARK: Settings

    var settings: some View {
        Form {
            Section("Folder layout") {
                TextField("Layout", text: $template, prompt: Text("{taken:yyyy}/{taken:MM}"))
                    .font(.system(.body, design: .monospaced))
                HStack {
                    // Titles name files, not folders (a folder per title would hold one file each).
                    FieldMenu(excluding: ["{title}", "{title:clean}", "{n:3}", "{name}"]) { template = appending($0, to: template) }
                    Button("Add Level /") { template += template.hasSuffix("/") || template.isEmpty ? "" : "/" }
                }
                Text("“/” makes a subfolder. Example: {taken:yyyy}/{taken:MM} → 2016/05")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Only Split into Numbered Folders") { template = "." }
                    .help("Keep files in this folder, but move them into subfolders 001, 002… of at most \(maxPerFolder) files each — e.g. to fix an “Unsorted” folder that’s too big to open quickly")
            }
            Section("Group by range") {
                GroupByRangeRow { template = appending($0, to: template == "." ? "" : template) }
                Text("Files go into folders by range, e.g. {duration|30m} → “Under 30 min”, “30 min or longer”. Combine with “/”: {quality}/{duration|30m}.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Section("Rename files (optional)") {
                TextField("Rename files to", text: $nameTemplate, prompt: Text("Keep their names"))
                    .font(.system(.body, design: .monospaced))
                HStack {
                    FieldMenu { nameTemplate = appending($0, to: nameTemplate) }
                    if titlesFound {
                        Button("Use Title Inside the File") { nameTemplate = "{title:clean}" }
                            .help("e.g. file000070.avi → Edge of Tomorrow (2014).avi")
                    }
                    if !nameTemplate.isEmpty {
                        Button("Keep Names") { nameTemplate = "" }
                    }
                }
                Text("The extension is kept. Files missing a detail the name needs keep their own name; same names get “ 2”, “ 3”.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Section("Use parts of the file name (optional)") {
                TextField("Pattern", text: $namePattern, prompt: Text(#"e.g. ^(\w+)-(\d{4})"#))
                    .font(.system(.body, design: .monospaced))
                Text("A regular expression matched against each name. Its (bracketed) parts become {1}, {2}… in the layout. E.g. INV-2015-001 → {1}/{2} → INV/2015")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Section("Files missing a detail") {
                TextField("Go to folder", text: $fallback)
            }
            Section("Big folders") {
                TextField("Max files per folder", value: $maxPerFolder, format: .number)
                Text(maxPerFolder > 0
                     ? "A folder that would hold more than \(maxPerFolder.formatted()) files gets numbered subfolders 001, 002… instead (folders with a huge number of files are slow to open). Files already there count too. 0 = no limit."
                     : "No limit: folders can hold any number of files.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Section("Where and how") {
                Picker("Put folders in", selection: $intoOtherPane) {
                    Text(request.root.lastPathComponent.isEmpty ? "/" : "“\(request.root.lastPathComponent)” (here)").tag(false)
                    Text("“\(request.otherFolder.lastPathComponent)” (other pane)").tag(true)
                }
                Picker("Files are", selection: $move) {
                    Text("Moved").tag(true)
                    Text("Copied").tag(false)
                }
                .pickerStyle(.segmented)
                if move {
                    Toggle("Remove folders left empty", isOn: $removeEmpty)
                }
            }
            Section {
                CoverageList(scan: scan) { template = appending($0, to: template) }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: Preview

    var preview: some View {
        let folders = summary.folders
        let shown: [OrganizeItem]
        if let selectedFolder, let indices = summary.itemsByFolder[selectedFolder] {
            shown = indices.map { plan.items[$0] }
        } else {
            shown = plan.items
        }
        return VSplitView {
            VStack(alignment: .leading, spacing: 0) {
                Text("New folders in “\(root.lastPathComponent)”").font(.headline).padding(10)
                List(selection: $selectedFolder) {
                    ForEach(folders, id: \.path) { folder in
                        HStack {
                            Image(systemName: folder.path == fallback ? "questionmark.folder" : "folder")
                                .foregroundStyle(folder.path == fallback ? .orange : .accentColor)
                            Text(folder.path)
                            Spacer()
                            Text("\(folder.count)").foregroundStyle(.secondary).monospacedDigit()
                        }
                        .tag(Optional(folder.path))
                    }
                }
                .listStyle(.inset)
                .overlay {
                    if let error = plan.error {
                        Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red).padding()
                    } else if folders.isEmpty {
                        Text(scan.phase == .listing || scan.phase == .sampling ? "Looking at the files…" : "Nothing to organize").foregroundStyle(.tertiary)
                    }
                }
            }
            .frame(minHeight: 160)
            Table(shown) {
                TableColumn("File") { item in
                    Text(OrganizePlanner.relativePath(item.source, request.root)).lineLimit(1).truncationMode(.middle)
                }
                TableColumn("Goes to") { item in
                    switch item.status {
                    case .unchanged: Text("Already in place").foregroundStyle(.secondary)
                    case .notRead: Text("Details not read yet").foregroundStyle(.tertiary)
                    case let .invalid(reason): Text(reason).foregroundStyle(.red)
                    default:
                        Text(OrganizePlanner.relativePath(item.destination, root)).lineLimit(1).truncationMode(.middle)
                    }
                }
                TableColumn("") { item in
                    if case let .fallback(fields) = item.status {
                        Image(systemName: "questionmark.circle").foregroundStyle(.orange).help("No \(fields)")
                    }
                }
                .width(24)
            }
            .frame(minHeight: 200)
        }
    }

    // MARK: Footer

    /// What happens between clicking Move and the job appearing in the queue.
    enum Handoff: Equatable {
        case reading, planning, queueing
    }

    var footer: some View {
        HStack(spacing: 12) {
            if let handoff {
                HandoffStatus(text: handoffText(handoff), since: handoffStarted)
            } else if let handoffError {
                Label(handoffError, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                if let overlappingPlan {
                    Button("Add Anyway") { Task { await submit(overlappingPlan, allowOverlap: true) } }
                        .help("Add it to the queue anyway; files the other job moves first will be skipped")
                }
            } else if let error = plan.error {
                Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
            } else {
                Text(footerText).foregroundStyle(.secondary)
            }
            Spacer()
            Button(handoff == .reading ? "Stop" : "Cancel", role: .cancel) {
                if handoff == .reading {
                    scan.stopReading()
                    handoff = nil
                } else {
                    scan.cancel()
                    dismiss()
                }
            }
            .keyboardShortcut(.cancelAction)
            .disabled(handoff == .planning || handoff == .queueing) // the job is being added; it can be cancelled from the queue
            if waitingForDetails {
                // The layout uses photo/video details: read the rest first, then go.
                Button("Read All & \(move ? "Move" : "Copy")") {
                    Task { await readAllThenSubmit() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(handoff != nil || scan.phase == .listing || plan.error != nil)
                .help("Reads the details of the remaining \(scan.unread.count) files, then \(move ? "moves" : "copies") everything")
            } else {
                Button("\(move ? "Move" : "Copy") \(summary.moving)") { Task { await submit(plan) } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(handoff != nil || scan.phase == .listing || summary.moving == 0 || plan.error != nil || summary.invalid > 0)
            }
        }
        .padding(12)
    }

    func handoffText(_ step: Handoff) -> String {
        switch step {
        case .reading:
            return "Reading details (\(scan.readCount.formatted()) of \(scan.files.count.formatted())) — then the job is added to the queue"
        case .planning:
            return "Working out where \(scan.files.count.formatted()) files go…"
        case .queueing:
            return "Adding \(summary.moving.formatted()) files to the queue…"
        }
    }

    var footerText: String {
        var text = "\(summary.moving) file\(summary.moving == 1 ? "" : "s") into \(summary.folders.count) folder\(summary.folders.count == 1 ? "" : "s")"
        if summary.fallback > 0 { text += " · \(summary.fallback) to “\(fallback)”" }
        if summary.notRead > 0 { text += " · \(summary.notRead) not read yet" }
        if summary.invalid > 0 { text += " · \(summary.invalid) can’t be placed" }
        return text
    }

    func begin(_ step: Handoff) {
        if handoff == nil { handoffStarted = Date() }
        handoff = step
        handoffError = nil
    }

    /// Adds the job and waits until it's in the queue; only then does the window close.
    func submit(_ plan: OrganizePlanner.Plan, allowOverlap: Bool = false) async {
        begin(.queueing)
        overlappingPlan = nil
        // Only folders inside the one being organized are ever removed, and only if empty.
        let outcome = await model.organize(plan.items, move: move, cleanUpIn: move && removeEmpty ? request.root : nil,
                                           allowOverlap: allowOverlap)
        handoff = nil
        switch outcome {
        case .added: dismiss()
        case let .failed(message): handoffError = message
        case let .overlaps(message):
            handoffError = message
            overlappingPlan = plan
        }
    }

    /// "Read All & Move": finish reading details, re-plan with all of them, then submit.
    func readAllThenSubmit() async {
        begin(.reading)
        await scan.readAll()
        guard handoff == .reading, scan.unread.isEmpty else { handoff = nil; return } // stopped
        begin(.planning)
        let final = await computePlan()
        let finalSummary = await Task.detached(priority: .userInitiated) { [root] in OrganizeSummary(final, root: root) }.value
        plan = final
        summary = finalSummary
        guard final.error == nil, finalSummary.invalid == 0 else {
            handoff = nil // let the user see what's wrong
            return
        }
        await submit(final)
    }

    func computePlan() async -> OrganizePlanner.Plan {
        let files = scan.files, metadata = scan.metadata, unread = scan.unread, root = self.root
        let options = OrganizeOptions(template: template, namePattern: namePattern, fallbackFolder: fallback,
                                      maxPerFolder: max(0, maxPerFolder), nameTemplate: nameTemplate)
        return await Task.detached(priority: .userInitiated) {
            OrganizePlanner.plan(files: files, root: root, options: options, metadata: metadata, unread: unread)
        }.value
    }

    func schedulePlan() {
        planTask?.cancel()
        let root = self.root
        planTask = Task {
            try? await Task.sleep(for: .milliseconds(150))
            if Task.isCancelled { return }
            let result = await computePlan()
            let newSummary = await Task.detached(priority: .userInitiated) { OrganizeSummary(result, root: root) }.value
            if !Task.isCancelled {
                plan = result
                summary = newSummary
                if let selected = selectedFolder, newSummary.itemsByFolder[selected] == nil {
                    selectedFolder = nil
                }
            }
        }
    }
}

/// Everything the window shows about a plan, computed once (off the main thread).
struct OrganizeSummary: Sendable {
    var folders: [(path: String, count: Int)] = []
    /// Folder path → indices of the plan's items going there.
    var itemsByFolder: [String: [Int]] = [:]
    var moving = 0
    var fallback = 0
    var invalid = 0
    var notRead = 0

    init() {}

    init(_ plan: OrganizePlanner.Plan, root: URL) {
        for (index, item) in plan.items.enumerated() {
            switch item.status {
            case .ok: moving += 1
            case .fallback: moving += 1; fallback += 1
            case .invalid: invalid += 1
            case .notRead: notRead += 1
            case .unchanged: break
            }
            if item.status.willMove {
                itemsByFolder[OrganizePlanner.relativePath(item.destination.deletingLastPathComponent(), root), default: []].append(index)
            }
        }
        folders = itemsByFolder.map { ($0.key, $0.value.count) }
            .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }
}

struct OrganizeRequest: Identifiable {
    /// What to organize: selected items, or the folder's contents.
    let inputs: [URL]
    /// The folder being organized (new folders go here by default).
    let root: URL
    /// The other pane's folder (alternative destination).
    let otherFolder: URL
    let id = UUID()
}


/// "Adding 16,000 files to the queue… 4 s" — with a spinner and a ticking clock, so it's clearly still working.
struct HandoffStatus: View {
    let text: String
    let since: Date

    var body: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(text).lineLimit(1)
            TimelineView(.periodic(from: since, by: 1)) { context in
                let seconds = Int(context.date.timeIntervalSince(since))
                if seconds >= 1 {
                    Text("\(seconds) s").monospacedDigit().foregroundStyle(.secondary)
                }
            }
        }
        .font(.callout)
        .accessibilityElement(children: .combine)
    }
}

/// "Group by range": pick a detail and limits; shows the folder names it will make, then inserts the field.
struct GroupByRangeRow: View {
    let insert: (String) -> Void
    @ViewState private var field: RangeField = .size
    @ViewState private var limits = "100MB,1GB"

    var parsed: [Double]? { field.parseLimits(limits) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Two short lines, so the settings column never has to grow wider than the window.
            HStack {
                Picker("Group by", selection: $field) {
                    ForEach(RangeField.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
                .onChange(of: field) { _, f in limits = f.examples.first?.limits ?? "" }
                Spacer(minLength: 4)
                Menu("Examples") {
                    ForEach(field.examples, id: \.limits) { example in
                        Button(example.title) { limits = example.limits }
                    }
                    if field == .res {
                        Divider()
                        Button("Standard classes: SD · 720p · 1080p · 1440p · 4K") { insert("{quality}") }
                    }
                }
                .fixedSize()
            }
            HStack {
                TextField("Limits", text: $limits, prompt: Text(field.placeholder))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                Button("Insert") { insert("{\(field.rawValue)|\(limits.replacingOccurrences(of: " ", with: ""))}") }
                    .disabled(parsed == nil)
            }
            if let parsed {
                Text("Folders: " + field.allRangeNames(parsed).joined(separator: "  ·  "))
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Couldn’t read the limits — separate them with commas, \(field.placeholder.replacingOccurrences(of: "e.g. ", with: "like "))")
                    .font(.caption).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
