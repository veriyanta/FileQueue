import AppKit
import FileQueueCore
import SwiftUI

@main
struct FileQueueApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    private let model = AppModel.shared
    @AppStorage(SettingsKey.showMenuBar) private var showMenuBar = true

    var body: some Scene {
        Window("FileQueue", id: "main") {
            ContentView()
                .environment(model)
                .frame(minWidth: 1100, minHeight: 640)
        }
        .defaultSize(width: 1400, height: 880)
        .commands { AppCommands(model: model) }

        WindowGroup("Disk Map", id: "diskmap", for: URL.self) { $url in
            if let url {
                DiskMapWindow(url: url)
                    .environment(model)
            }
        }
        .defaultSize(width: 1100, height: 720)

        WindowGroup("Empty Folders", id: "emptyfolders", for: URL.self) { $url in
            if let url {
                EmptyFoldersWindow(url: url)
                    .environment(model)
            }
        }
        .defaultSize(width: 720, height: 560)

        WindowGroup("Duplicates", id: "duplicates", for: URL.self) { $url in
            if let url {
                DuplicatesWindow(url: url)
                    .environment(model)
            }
        }
        .defaultSize(width: 1100, height: 760)

        Settings {
            SettingsView()
                .environment(model)
        }

        MenuBarExtra(isInserted: $showMenuBar) {
            MenuBarContent()
                .environment(model)
        } label: {
            MenuBarLabel(model: model)
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Needed when launched as a bare executable (`swift run`) rather than an .app bundle.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Files dropped on the Dock icon or opened with "Open With → FileQueue".
    func application(_ application: NSApplication, open urls: [URL]) {
        MainActor.assumeIsolated { AppModel.shared.reveal(urls.filter(\.isFileURL)) }
    }
}

struct AppCommands: Commands {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Folder") { model.newFolder() }
                .keyboardShortcut("n", modifiers: [.command, .shift])
        }
        CommandGroup(replacing: .undoRedo) {
            Button("Undo") {
                // Text fields keep their own undo; elsewhere ⌘Z undoes the last file operation.
                if NSApp.keyWindow?.firstResponder is NSTextView {
                    NSApp.sendAction(Selector(("undo:")), to: nil, from: nil)
                } else {
                    model.undoLast()
                }
            }
            .keyboardShortcut("z")
            Button("Redo") { NSApp.sendAction(Selector(("redo:")), to: nil, from: nil) }
                .keyboardShortcut("z", modifiers: [.command, .shift])
        }
        CommandMenu("Actions") {
            Button("Copy to Other Pane") { model.transferSelection(move: false) }
                .keyboardShortcut("c", modifiers: [.command, .shift])
                .disabled(!model.canCopy)
            Button("Move to Other Pane") { model.transferSelection(move: true) }
                .keyboardShortcut("m", modifiers: [.command, .shift])
                .disabled(!model.canMove)
            Button("Rename…") { model.beginRename() }
                .keyboardShortcut("r")
                .disabled(!model.canModify)
            Button("Batch Rename…") { model.beginBatchRename() }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(!model.canModify)
            Button("Organize into Folders…") { model.beginOrganize() }
                .keyboardShortcut("o", modifiers: [.command, .option])
            Button("Remove Empty Folders…") { openWindow(id: "emptyfolders", value: model.diskMapTarget) }
                .keyboardShortcut("e", modifiers: [.command, .option])
                .disabled(model.activePane.isReadOnly)
            Divider()
            Button("Show Disk Map") { openWindow(id: "diskmap", value: model.diskMapTarget) }
                .keyboardShortcut("m", modifiers: [.command, .option])
            Button("Find Duplicates…") { openWindow(id: "duplicates", value: model.diskMapTarget) }
                .keyboardShortcut("d", modifiers: [.command, .option])
            Divider()
            Button("Move to Trash") { model.confirmTrash = true }
                .keyboardShortcut(.delete)
                .disabled(!model.canModify)
        }
        CommandMenu("Go") {
            Button("Back") { model.activePane.goBack() }
                .keyboardShortcut("[")
            Button("Forward") { model.activePane.goForward() }
                .keyboardShortcut("]")
            Button("Enclosing Folder") { model.activePane.goUp() }
                .keyboardShortcut(.upArrow)
            Divider()
            Button("Switch to Other Pane") {
                model.activeSide = model.activeSide == .source ? .destination : .source
            }
            .keyboardShortcut("\\", modifiers: [.command])
            Button("Swap Panes") { model.swapPanes() }
                .keyboardShortcut("u")
            Divider()
            Button("as List") { model.activePane.viewMode = .list }
                .keyboardShortcut("1")
            Button("as Thumbnails") { model.activePane.viewMode = .thumbnails }
                .keyboardShortcut("2")
            Button("Bigger Thumbnails") { model.activePane.thumbnailSize = min(420, model.activePane.thumbnailSize + 40) }
                .keyboardShortcut("+")
            Button("Smaller Thumbnails") { model.activePane.thumbnailSize = max(80, model.activePane.thumbnailSize - 40) }
                .keyboardShortcut("-")
            Button("Select All in Pane") { model.activePane.selectAll() }
                .keyboardShortcut("a", modifiers: [.command, .option])
            Button("Quick Look") { QuickLook.shared.toggle(model.activePane.selectedURLs) }
                .keyboardShortcut("y")
            Divider()
            Button(model.activePane.showHidden ? "Hide Hidden Files" : "Show Hidden Files") {
                model.activePane.showHidden.toggle()
            }
            .keyboardShortcut(".", modifiers: [.command, .shift])
        }
        CommandMenu("Queue") {
            Button("Pause All") { model.pauseAll() }
                .keyboardShortcut("p", modifiers: [.command, .option])
            Button("Resume All") { model.resumeAll() }
                .keyboardShortcut("r", modifiers: [.command, .option])
            Divider()
            Button("Undo Last Operation") { model.undoLast() }
                .disabled(!model.canUndo)
            Button("Clear Finished") { model.clearFinished() }
                .keyboardShortcut("k")
        }
    }
}
