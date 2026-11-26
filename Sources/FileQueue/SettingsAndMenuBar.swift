import FileQueueCore
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @AppStorage(SettingsKey.showMenuBar) private var showMenuBar = true

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                Stepper("Run up to \(model.maxConcurrent) job\(model.maxConcurrent == 1 ? "" : "s") at once",
                        value: $model.maxConcurrent, in: 1...8)
                Text("Jobs on the same disk always wait their turn. Jobs on different disks run in parallel, up to this limit.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Picker("When a file already exists", selection: $model.defaultPolicy) {
                    ForEach(ConflictPolicy.allCases) { Text($0.label).tag($0) }
                }
                Text("Merge: existing folders are filled in — files already there (same size and date) are skipped, missing ones copied, and you’re asked about files that differ.\nMerge, Keep Both if Different: never asks — files with the same name get a quick content check (size plus samples of the bytes, not dates). The same: left as is. Different: both are kept, the incoming one renamed (“name 2.ext”).")
                    .font(.caption).foregroundStyle(.secondary)
                Picker("When an item can’t be read or written", selection: $model.onError) {
                    ForEach(ErrorPolicy.allCases) { Text($0.label).tag($0) }
                }
                Toggle("Verify with checksums", isOn: $model.verifyChecksums)
                Text("Slower, but compares every byte: before deleting an original after a move, and when deciding a file is already there.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Toggle("Show progress in the menu bar", isOn: $showMenuBar)
            }
            VideoPreviewSection()
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .fixedSize()
    }
}

struct MenuBarLabel: View {
    let model: AppModel

    var body: some View {
        if let progress = model.overallProgress {
            Image(systemName: "arrow.triangle.2.circlepath")
            Text("\(Int(progress * 100))%")
        } else {
            Image(systemName: "tray.full")
        }
    }
}

struct MenuBarContent: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if model.runningJobs.isEmpty {
                Text(model.hasActiveJobs ? "Jobs are waiting" : "Nothing running")
                    .foregroundStyle(.secondary)
            }
            ForEach(model.runningJobs) { job in
                VStack(alignment: .leading, spacing: 3) {
                    Text(job.title).lineLimit(1).truncationMode(.middle)
                    ProgressView(value: job.progress.fraction)
                    Text(job.state == .paused ? "Paused" : job.disks.map(\.name).joined(separator: " → "))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Divider()
            HStack {
                Button("Open FileQueue") {
                    openWindow(id: "main")
                    NSApp.activate(ignoringOtherApps: true)
                }
                Spacer()
                Button { model.pauseAll() } label: { Label("Pause All", systemImage: "pause.fill") }
                Button { model.resumeAll() } label: { Label("Resume All", systemImage: "play.fill") }
                Button { NSApp.terminate(nil) } label: { Label("Quit", systemImage: "power") }
            }
            .labelStyle(.iconOnly)
        }
        .padding(12)
        .frame(width: 300)
    }
}

/// Whether ffmpeg is there to preview videos macOS can't decode.
struct VideoPreviewSection: View {
    @ViewState private var ffmpeg = FFmpegFrame.executable

    var body: some View {
        Section("Video previews") {
            if let ffmpeg {
                LabeledContent("ffmpeg", value: ffmpeg.path)
                Text("Used for thumbnails of videos macOS can’t decode itself (XviD, CineForm, WMV, FLV…).")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                LabeledContent("ffmpeg", value: "Not installed")
                Text("MP4, MOV, MKV (H.264, HEVC, MPEG-2) and most AVIs are previewed without it. For the rest — XviD, GoPro CineForm, WMV, FLV and other older formats — install ffmpeg with Homebrew in Terminal: brew install ffmpeg")
                    .font(.caption).foregroundStyle(.secondary)
                    .textSelection(.enabled)
                Button("Check Again") { ffmpeg = FFmpegFrame.executable }
            }
        }
    }
}
