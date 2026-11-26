import AppKit
import FileQueueCore
import SwiftUI
import UniformTypeIdentifiers

struct BatchRenameView: View {
    let inputs: [URL]
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @ViewState private var scan: MediaScan
    @ViewState private var rules: [RenameRule] = [.replace("", with: "")]
    @ViewState private var numberDuplicates = true
    @ViewState private var plan: [RenamePlanItem] = []
    @ViewState private var planTask: Task<Void, Never>?
    /// Counts and the common folder, worked out once per plan (not on every redraw).
    @ViewState private var counts = RenameCounts()
    /// Set while the job is being handed to the queue (the window stays open until it's there).
    @ViewState private var handoff: String?
    @ViewState private var handoffStarted = Date()
    @ViewState private var handoffError: String?
    @ViewState private var readingFirst = false
    /// The plan that clashed with a queued job, ready for "Add Anyway".
    @ViewState private var overlappingPlan: [RenamePlanItem]?

    init(files: [URL]) {
        inputs = files
        _scan = ViewState(initialValue: MediaScan(inputs: files))
    }

    var errorCount: Int { counts.errors }
    var changeCount: Int { counts.changes }
    var missingCount: Int { counts.missing }
    /// Rules need photo/video details (date taken, camera…) rather than just names.
    var needsDetails: Bool { rules.contains { $0.isEnabled && $0.kind == .metadata && NameTemplate.needsDetails($0.text) } }
    var waitingForDetails: Bool { needsDetails && !scan.unread.isEmpty }
    /// Folder names are shown when the files come from more than one folder.
    var commonRoot: URL? { counts.commonRoot }

    var body: some View {
        @Bindable var scan = scan
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                ScanStatus(scan: scan, needsDetails: needsDetails)
                if scan.hasFolders {
                    Toggle("Include files inside folders (and subfolders)", isOn: $scan.recursive)
                        .toggleStyle(.checkbox)
                        .help("Rename every file inside the selected folders instead of the folders themselves")
                }
                Spacer()
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            Divider()
            SuggestionBar(title: "Suggested names", suggestions: scan.renameSuggestions, scan: scan, apply: applySuggestion)
            Divider()
            HSplitView {
                ruleList.frame(minWidth: 340, idealWidth: 380)
                previewTable.frame(minWidth: 460)
            }
            Divider()
            HStack(spacing: 12) {
                Menu("Presets") {
                    Button("Save Preset…", action: savePreset)
                    Button("Load Preset…", action: loadPreset)
                }
                .fixedSize()
                Toggle("Number duplicates (“ 2”, “ 3”)", isOn: $numberDuplicates)
                    .toggleStyle(.checkbox)
                    .help("When several files would get the same name (e.g. photos taken in the same second), add a number instead of stopping")
                Spacer()
                if readingFirst {
                    HandoffStatus(text: "Reading details (\(scan.readCount.formatted()) of \(scan.files.count.formatted())) — then the renaming is added to the queue",
                                  since: handoffStarted)
                } else if let handoff {
                    HandoffStatus(text: handoff, since: handoffStarted)
                } else if let handoffError {
                    Label(handoffError, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red).lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                    if let overlappingPlan {
                        Button("Add Anyway") { Task { await submit(overlappingPlan, count: changeCount, allowOverlap: true) } }
                    }
                } else if errorCount > 0 {
                    Label("\(errorCount) problem\(errorCount == 1 ? "" : "s") to fix", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                } else {
                    Text("\(changeCount) of \(plan.count) will be renamed"
                         + (missingCount > 0 ? " · \(missingCount) left as is (missing details)" : "")
                         + (counts.notRead > 0 ? " · \(counts.notRead) not read yet" : ""))
                        .foregroundStyle(.secondary)
                }
                Button(readingFirst ? "Stop" : "Cancel", role: .cancel) {
                    if readingFirst {
                        scan.stopReading()
                        readingFirst = false
                    } else {
                        scan.cancel()
                        dismiss()
                    }
                }
                .keyboardShortcut(.cancelAction)
                .disabled(handoff != nil)
                if waitingForDetails {
                    Button("Read All & Rename") { Task { await readAllThenRename() } }
                        .keyboardShortcut(.defaultAction)
                        .disabled(readingFirst || handoff != nil || scan.phase == .listing)
                        .help("Reads the details of the remaining \(scan.unread.count) files, then renames")
                } else {
                    Button("Rename \(changeCount)") { Task { await submit(plan, count: changeCount) } }
                        .keyboardShortcut(.defaultAction)
                        .disabled(handoff != nil || errorCount > 0 || changeCount == 0 || scan.phase == .listing)
                }
            }
            .padding(12)
        }
        .frame(minWidth: 1000, idealWidth: 1100, maxWidth: 1500, minHeight: 620, idealHeight: 740)
        .onAppear(perform: schedulePlan)
        .onChange(of: rules) { schedulePlan() }
        .onChange(of: numberDuplicates) { schedulePlan() }
        .onChange(of: scan.version) { schedulePlan() }
    }

    func computePlan() async -> ([RenamePlanItem], RenameCounts) {
        let files = scan.files, rules = self.rules, metadata = scan.metadata, unread = scan.unread
        let options = RenameEngine.Options(numberDuplicates: numberDuplicates)
        return await Task.detached(priority: .userInitiated) {
            let plan = RenameEngine.makePlan(files: files, rules: rules, fileMetadata: metadata, options: options, unread: unread)
            return (plan, RenameCounts(plan))
        }.value
    }

    /// Recomputes the preview off the main thread (folders can hold thousands of files).
    func schedulePlan() {
        planTask?.cancel()
        planTask = Task {
            try? await Task.sleep(for: .milliseconds(150))
            if Task.isCancelled { return }
            let (result, newCounts) = await computePlan()
            if !Task.isCancelled {
                plan = result
                counts = newCounts
            }
        }
    }

    /// Adds the renaming and waits until it's in the queue; only then does the window close.
    func submit(_ plan: [RenamePlanItem], count: Int, allowOverlap: Bool = false) async {
        if handoff == nil && !readingFirst { handoffStarted = Date() }
        handoffError = nil
        overlappingPlan = nil
        handoff = "Adding \(count.formatted()) renames to the queue…"
        let outcome = await model.batchRename(plan, allowOverlap: allowOverlap)
        handoff = nil
        switch outcome {
        case .added: dismiss()
        case let .failed(message): handoffError = message
        case let .overlaps(message):
            handoffError = message
            overlappingPlan = plan
        }
    }

    /// "Read All & Rename": finish reading details, re-plan with all of them, then rename.
    func readAllThenRename() async {
        handoffStarted = Date()
        handoffError = nil
        readingFirst = true
        await scan.readAll()
        guard readingFirst, scan.unread.isEmpty else { readingFirst = false; return } // stopped
        readingFirst = false
        handoff = "Working out the new names for \(scan.files.count.formatted()) files…"
        let (final, finalCounts) = await computePlan()
        plan = final
        counts = finalCounts
        guard finalCounts.errors == 0, finalCounts.changes > 0 else { handoff = nil; return } // let the user see what's wrong
        await submit(final, count: finalCounts.changes)
    }

    /// Uses a suggested template: fills the first Metadata rule, or adds one at the top.
    func applySuggestion(_ template: String) {
        if let i = rules.firstIndex(where: { $0.kind == .metadata }) {
            rules[i].text = template
            rules[i].isEnabled = true
            rules[i].placement = .replace
        } else {
            rules.removeAll { $0.kind == .replace && $0.text.isEmpty } // the empty starter rule
            rules.insert(.metadata(template), at: 0)
        }
        numberDuplicates = true
    }

    /// Adds a field to the first Metadata rule (creating one if needed).
    func insertField(_ token: String) {
        if let i = rules.firstIndex(where: { $0.kind == .metadata }) {
            rules[i].text = appending(token, to: rules[i].text)
            rules[i].isEnabled = true
        } else {
            rules.removeAll { $0.kind == .replace && $0.text.isEmpty }
            rules.insert(.metadata(token), at: 0)
        }
    }

    // MARK: Rules

    var ruleList: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Rules").font(.headline)
                Text("applied top to bottom").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Menu {
                    ForEach(RenameRule.Kind.allCases) { kind in
                        Button(kind.label) { rules.append(RenameRule(kind: kind)) }
                    }
                } label: {
                    Label("Add Rule", systemImage: "plus")
                }
                .fixedSize()
            }
            .padding(12)
            List {
                ForEach($rules) { $rule in
                    RuleEditor(rule: $rule, multipleFolders: commonRoot != nil) { rules.removeAll { $0.id == rule.id } }
                }
                .onMove { rules.move(fromOffsets: $0, toOffset: $1) }
            }
            .listStyle(.inset)
            Divider()
            ScrollView {
                CoverageList(scan: scan, insert: insertField)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 190)
        }
    }

    // MARK: Preview

    var previewTable: some View {
        let root = commonRoot
        return Table(plan) {
            TableColumn("Original") { item in
                Text(root.map { OrganizePlanner.relativePath(item.original, $0) } ?? item.original.lastPathComponent)
                    .foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.head)
            }
            TableColumn("New Name") { item in
                Text(item.proposedName)
                    .foregroundStyle(item.status.isError ? Color.red : item.status == .ok ? Color.primary : Color.secondary)
            }
            TableColumn("") { item in
                statusIcon(item.status)
            }
            .width(26)
        }
        .overlay {
            if plan.isEmpty && !scan.isBusy {
                Text(scan.files.isEmpty ? "No files" : "Add a rule or pick a suggestion").foregroundStyle(.tertiary)
            }
        }
    }

    @ViewBuilder func statusIcon(_ status: RenameStatus) -> some View {
        switch status {
        case .ok:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).accessibilityLabel("OK")
        case .unchanged:
            Image(systemName: "minus.circle").foregroundStyle(.secondary).accessibilityLabel("Unchanged")
        case .notRead:
            Image(systemName: "hourglass").foregroundStyle(.tertiary)
                .help("Details not read yet").accessibilityLabel("Details not read yet")
        case .missingMetadata:
            Image(systemName: "questionmark.circle").foregroundStyle(.orange)
                .help(status.label).accessibilityLabel(status.label)
        default:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                .help(status.label).accessibilityLabel(status.label)
        }
    }

    // MARK: Presets

    func savePreset() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "Rename preset.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = .prettyPrinted
            try encoder.encode(rules).write(to: url)
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    func loadPreset() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            rules = try JSONDecoder().decode([RenameRule].self, from: Data(contentsOf: url))
                .map { var r = $0; r.id = UUID(); return r }
        } catch {
            NSAlert(error: error).runModal()
        }
    }
}

struct RuleEditor: View {
    @Binding var rule: RenameRule
    var multipleFolders = false
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Toggle(isOn: $rule.isEnabled) { Text(rule.kind.label).font(.subheadline.weight(.semibold)) }
                    .toggleStyle(.checkbox)
                Spacer()
                Button(action: onDelete) { Label("Remove rule", systemImage: "minus.circle").labelStyle(.iconOnly) }
                    .buttonStyle(.borderless)
                    .help("Remove rule")
            }
            fields
                .disabled(!rule.isEnabled)
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder var fields: some View {
        switch rule.kind {
        case .metadata:
            TextField("Template, e.g. {taken:yyyy-MM-dd} {camera}", text: $rule.text)
                .font(.system(.body, design: .monospaced))
            HStack {
                FieldMenu { rule.text = appending($0, to: rule.text) }
                placementPicker
                if rule.placement != .replace {
                    TextField("Separator", text: $rule.separator).frame(width: 70)
                }
            }
            if rule.text.contains("{n") {
                Toggle("Restart counter in each folder", isOn: $rule.perFolder).toggleStyle(.checkbox)
            }
            Text("Files missing a detail keep their name.").font(.caption).foregroundStyle(.secondary)
        case .replace:
            TextField("Find", text: $rule.text)
            TextField(rule.useRegex ? "Replace with ($1 for groups)" : "Replace with", text: $rule.replacement)
            HStack {
                Toggle("Regular expression", isOn: $rule.useRegex)
                Toggle("Match case", isOn: $rule.caseSensitive)
            }
            .toggleStyle(.checkbox)
        case .addPrefix:
            TextField("Prefix", text: $rule.text)
        case .addSuffix:
            TextField("Suffix (before the extension)", text: $rule.text)
        case .insert:
            TextField("Text", text: $rule.text)
            Stepper("At position \(rule.position)", value: $rule.position, in: 0...255)
        case .remove:
            Stepper("From position \(rule.position)", value: $rule.position, in: 0...255)
            Stepper("Remove \(rule.count) character\(rule.count == 1 ? "" : "s")", value: $rule.count, in: 1...255)
        case .changeCase:
            Picker("Case", selection: $rule.caseStyle) {
                ForEach(RenameRule.CaseStyle.allCases) { Text($0.label).tag($0) }
            }
            .labelsHidden()
        case .sequence:
            HStack {
                Stepper("Start \(rule.start)", value: $rule.start, in: 0...99_999)
                Stepper("Step \(rule.step)", value: $rule.step, in: 1...1000)
            }
            HStack {
                Stepper("Digits \(rule.padding)", value: $rule.padding, in: 1...8)
                placementPicker
            }
            TextField("Separator", text: $rule.separator)
            if multipleFolders {
                Toggle("Restart in each folder", isOn: $rule.perFolder).toggleStyle(.checkbox)
            }
        case .date:
            Picker("Date", selection: $rule.dateSource) {
                ForEach(RenameRule.DateSource.allCases) { Text($0.label).tag($0) }
            }
            TextField("Format, e.g. yyyy-MM-dd HH.mm", text: $rule.dateFormat)
            HStack {
                placementPicker
                TextField("Separator", text: $rule.separator).frame(width: 80)
            }
        case .setExtension:
            TextField("New extension (empty removes it)", text: $rule.text)
        case .trimWhitespace:
            Text("Removes spaces at the start and end of the name.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    var placementPicker: some View {
        Picker("Position", selection: $rule.placement) {
            ForEach(RenameRule.Placement.allCases) { Text($0.label).tag($0) }
        }
        .labelsHidden()
        .fixedSize()
    }
}


/// Counts for the rename window, computed once per plan (off the main thread).
struct RenameCounts: Sendable {
    var errors = 0
    var changes = 0
    var missing = 0
    var notRead = 0
    /// Set when the files come from more than one folder.
    var commonRoot: URL?

    init() {}

    init(_ plan: [RenamePlanItem]) {
        var dirs = Set<URL>()
        for item in plan {
            switch item.status {
            case .ok: changes += 1
            case .missingMetadata: missing += 1
            case .notRead: notRead += 1
            case .unchanged: break
            default: errors += 1
            }
            dirs.insert(item.original.deletingLastPathComponent())
        }
        guard dirs.count > 1, var root = dirs.first else { return }
        while !dirs.allSatisfy({ FS.isSameOrInside($0, root) }) {
            let parent = root.deletingLastPathComponent()
            if parent.path == root.path { break }
            root = parent
        }
        commonRoot = root
    }
}
