import AppKit
import SwiftUI

final class StudioAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
}

struct StudioCommandActions {
    let newProject: () -> Void
    let openProject: () -> Void
    let saveProject: () -> Void
    let copyBash: () -> Void
    let runPreview: () -> Void
}

private struct StudioCommandActionsKey: FocusedValueKey {
    typealias Value = StudioCommandActions
}

extension FocusedValues {
    var studioCommandActions: StudioCommandActions? {
        get { self[StudioCommandActionsKey.self] }
        set { self[StudioCommandActionsKey.self] = newValue }
    }
}

private struct StudioCommands: Commands {
    @FocusedValue(\.studioCommandActions) private var actions

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Project") { actions?.newProject() }
                .keyboardShortcut("n")
                .disabled(actions == nil)
            Button("Open Project…") { actions?.openProject() }
                .keyboardShortcut("o")
                .disabled(actions == nil)
            Button("Save Project As…") { actions?.saveProject() }
                .keyboardShortcut("s", modifiers: [.command, .shift])
                .disabled(actions == nil)
        }
        CommandMenu("Studio") {
            Button("Copy Bash Function") { actions?.copyBash() }
                .keyboardShortcut("c", modifiers: [.command, .option])
                .disabled(actions == nil)
            Button("Run Preview") { actions?.runPreview() }
                .keyboardShortcut("r", modifiers: [.command])
                .disabled(actions == nil)
        }
    }
}

@main
struct GovonerStudioApp: App {
    @NSApplicationDelegateAdaptor(StudioAppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup("Govoner Studio") {
            ContentView()
                .frame(minWidth: 960, minHeight: 620)
        }
        .defaultSize(width: 1240, height: 760)
        .commands { StudioCommands() }
    }
}
