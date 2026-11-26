import FileQueueCore
import SwiftUI

struct QueuePanel: View {
    @Environment(AppModel.self) private var model
    @ViewState private var showFinished = true

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Queue").font(.headline)
                Text("Same disk: one at a time · Different disks: in parallel")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button { model.pauseAll() } label: { Label("Pause All", systemImage: "pause.fill") }
                Button { model.resumeAll() } label: { Label("Resume All", systemImage: "play.fill") }
                Button { model.undoLast() } label: { Label("Undo Last", systemImage: "arrow.uturn.backward") }
                    .disabled(!model.canUndo)
                Button { model.clearFinished() } label: { Label("Clear Finished", systemImage: "xmark.circle") }
                    .disabled(model.finished.isEmpty)
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.bar)
            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if model.lanes.isEmpty && model.needsAttention.isEmpty && model.finished.isEmpty {
                        ContentUnavailableView("Nothing queued", systemImage: "tray",
                                               description: Text("Jobs you add appear here, grouped by disk."))
                            .padding(.top, 30)
                    }
                    ForEach(model.lanes) { lane in
                        LaneView(lane: lane)
                    }
                    if !model.needsAttention.isEmpty {
                        Section {
                            ForEach(model.needsAttention) { JobRow(job: $0, inLane: false) }
                        } header: {
                            SectionHeader(title: "Needs attention", systemImage: "exclamationmark.triangle", count: model.needsAttention.count)
                        }
                    }
                    if !model.finished.isEmpty {
                        Section {
                            if showFinished {
                                ForEach(model.finished) { JobRow(job: $0, inLane: false) }
                            }
                        } header: {
                            Button { showFinished.toggle() } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: showFinished ? "chevron.down" : "chevron.right")
                                        .font(.caption).frame(width: 10)
                                    SectionHeader(title: "Finished", systemImage: "checkmark.circle", count: model.finished.count)
                                }
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(showFinished ? "Hide finished jobs" : "Show finished jobs")
                        }
                    }
                }
                .padding(12)
            }
        }
    }
}

struct SectionHeader: View {
    let title: String
    let systemImage: String
    let count: Int

    var body: some View {
        Label {
            Text(title).font(.subheadline.weight(.semibold))
            + Text("  \(count)").font(.subheadline).foregroundColor(.secondary)
        } icon: {
            Image(systemName: systemImage)
        }
    }
}

struct LaneView: View {
    let lane: Lane

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: lane.disks.count > 1 ? "externaldrive.connected.to.line.below" : diskSymbol(lane.disks.first))
                    .accessibilityHidden(true)
                Text(lane.disks.map(\.name).joined(separator: " + ")).font(.subheadline.weight(.semibold))
                let running = lane.jobs.filter { $0.state.isStarted }.count
                let waiting = lane.jobs.count - running
                Text(running > 0 ? "\(running) running\(waiting > 0 ? ", \(waiting) waiting" : "")" : "\(waiting) waiting")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            VStack(spacing: 0) {
                ForEach(Array(lane.jobs.enumerated()), id: \.element.id) { index, job in
                    if index > 0 { Divider() }
                    JobRow(job: job, inLane: true)
                }
            }
            .background(RoundedRectangle(cornerRadius: 8).fill(.background.secondary))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator))
        }
    }
}

func diskSymbol(_ disk: DiskInfo?) -> String {
    guard let disk else { return "internaldrive" }
    return disk.volumePath == "/" || disk.volumePath.hasPrefix("/System") ? "internaldrive" : "externaldrive"
}

struct JobRow: View {
    let job: Job
    /// Shown inside a disk lane (as opposed to the attention/finished lists).
    let inLane: Bool
    @Environment(AppModel.self) private var model

    /// "EXT-SSD-1 → 500GBExFat" for transfers between disks; otherwise the disk names.
    var route: String? {
        guard job.disks.count > 1 else { return nil }
        if let destID = job.destinationDisk, let dest = job.disks.first(where: { $0.id == destID }) {
            let sources = job.disks.filter { $0.id != destID }.map(\.name).joined(separator: ", ")
            return "\(sources) → \(dest.name)"
        }
        return job.disks.map(\.name).joined(separator: ", ")
    }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(tint)
                .frame(width: 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(job.title).lineLimit(1).truncationMode(.middle)
                    if let route {
                        Text(route)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(Capsule().fill(Color.secondary.opacity(0.12)))
                            .lineLimit(1)
                    }
                    if job.options.runInParallelAnyway {
                        Image(systemName: "bolt.fill").foregroundStyle(.orange)
                            .help("Runs in parallel regardless of disk")
                            .accessibilityLabel("Runs in parallel anyway")
                    }
                }
                Text(statusText).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                if job.state.isStarted {
                    ProgressView(value: job.progress.fraction)
                        .progressViewStyle(.linear)
                        .tint(job.state == .paused ? .gray : .accentColor)
                    Text(detailText).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                if !job.problems.isEmpty {
                    ProblemList(problems: job.problems)
                }
                ForEach(job.notes.prefix(3), id: \.self) { note in
                    Text(note).font(.caption2).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            controls
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder var controls: some View {
        HStack(spacing: 4) {
            switch job.state {
            case .running:
                iconButton("Pause", "pause.fill") { model.pause(job) }
                iconButton("Cancel", "xmark") { model.cancel(job) }
            case .paused:
                iconButton("Resume", "play.fill") { model.resume(job) }
                iconButton("Cancel", "xmark") { model.cancel(job) }
            case .pending, .waiting:
                iconButton("Move up", "arrow.up") { model.move(job, by: -1) }
                iconButton("Move down", "arrow.down") { model.move(job, by: 1) }
                iconButton("Hold", "pause") { model.pause(job) }
                iconButton("Cancel", "xmark") { model.cancel(job) }
            case .onHold:
                iconButton("Move up", "arrow.up") { model.move(job, by: -1) }
                iconButton("Move down", "arrow.down") { model.move(job, by: 1) }
                iconButton("Resume", "play.fill") { model.resume(job) }
                iconButton("Cancel", "xmark") { model.cancel(job) }
            case .interrupted:
                iconButton("Resume (restarts the job)", "play.fill") { model.resume(job) }
                iconButton("Remove", "trash") { model.remove(job) }
            case .failed, .cancelled:
                iconButton("Retry", "arrow.clockwise") { model.retry(job) }
                if job.canUndo { iconButton("Undo", "arrow.uturn.backward") { model.undo(job) } }
                iconButton("Remove", "minus.circle") { model.remove(job) }
            case .completed:
                if !job.problems.isEmpty {
                    iconButton("Retry (fetches only what’s missing)", "arrow.clockwise") { model.retry(job) }
                }
                if job.canUndo { iconButton("Undo", "arrow.uturn.backward") { model.undo(job) } }
                iconButton("Remove", "minus.circle") { model.remove(job) }
            }
        }
        .buttonStyle(.borderless)
    }

    func iconButton(_ title: String, _ systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Label(title, systemImage: systemImage).labelStyle(.iconOnly) }
            .help(title)
            .frame(width: 22, height: 22)
    }

    var icon: String {
        switch job.operation {
        case .copy: "doc.on.doc"
        case .move: "arrow.right.doc.on.clipboard"
        case .rename: "pencil"
        case .batchRename: "list.number"
        case .trash: "trash"
        case .organize: "folder.badge.gearshape"
        case .undo: "arrow.uturn.backward"
        }
    }

    var tint: Color {
        switch job.state {
        case .running: .accentColor
        case .completed: job.problems.isEmpty ? .green : .orange
        case .failed, .interrupted: .orange
        default: .secondary
        }
    }

    var statusText: String {
        switch job.state {
        case .pending: return "Queued"
        case let .waiting(disks):
            if disks.isEmpty { return "Waiting for a free slot (limit \(model.maxConcurrent) at once)" }
            return "Waiting for " + disks.sorted().map { job.diskName($0) }.joined(separator: " and ")
        case .running:
            if let item = job.progress.currentItem { return "\(job.operation.verb): \(item)" }
            return "Running"
        case .paused: return "Paused — still holding \(job.disks.map(\.name).joined(separator: ", "))"
        case .onHold: return "On hold"
        case .completed where !job.problems.isEmpty:
            let n = job.problems.count
            return "Done, but \(n) item\(n == 1 ? "" : "s") couldn’t be processed"
        case .completed:
            return "Done" + (job.finishedAt.map { " · \($0.formatted(date: .omitted, time: .shortened))" } ?? "") + (job.undone ? " · Undone" : "")
        case let .failed(reason): return "Failed: \(reason)"
        case .cancelled: return "Cancelled"
        case .interrupted: return "Interrupted when the app quit — resume to restart it"
        }
    }

    var detailText: String {
        let p = job.progress
        var parts: [String] = []
        if p.totalBytes > 0 {
            parts.append("\(Format.bytes(p.completedBytes)) of \(Format.bytes(p.totalBytes))")
        } else if p.totalFiles > 0 {
            parts.append("\(p.completedFiles) of \(p.totalFiles) items")
        }
        if job.state == .running, p.bytesPerSecond > 1 {
            parts.append("\(Format.bytes(Int64(p.bytesPerSecond)))/s")
            if let eta = p.secondsRemaining { parts.append("\(Format.duration(eta)) left") }
        }
        return parts.joined(separator: " · ")
    }
}


/// The items a job had to skip, collapsed to the first few.
struct ProblemList: View {
    let problems: [String]
    @ViewState private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(expanded ? problems : Array(problems.prefix(3)), id: \.self) { problem in
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .lineLimit(2)
                    .textSelection(.enabled)
            }
            if problems.count > 3 {
                Button(expanded ? "Show fewer" : "Show all \(problems.count)") { expanded.toggle() }
                    .buttonStyle(.link)
                    .font(.caption2)
            }
        }
    }
}
