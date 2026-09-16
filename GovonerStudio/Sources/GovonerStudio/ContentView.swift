import AppKit
import GovonerStudioCore
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @StateObject private var store = StudioStore()
    @ObservedObject private var recentProjects = RecentProjectsStore.shared
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var dragItem: StudioDragItem?
    @State private var importingProject = false
    @State private var exportingProject = false
    @State private var exportingBash = false
    @State private var projectDocument: StudioProjectDocument?
    @State private var bashDocument: BashScriptDocument?
    @State private var showBashPreview = false
    @State private var bashPreview = ""
    @State private var errorMessage: String?
    @State private var isStartingPreview = false

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            PaletteView(store: store, recentProjects: recentProjects, dragItem: $dragItem, openRecent: openProjectURL)
                .navigationSplitViewColumnWidth(min: 220, ideal: 250, max: 300)
        } content: {
            FlowCanvasView(store: store, dragItem: $dragItem)
                .navigationSplitViewColumnWidth(min: 390, ideal: 560)
        } detail: {
            inspector
                .navigationSplitViewColumnWidth(min: 300, ideal: 340, max: 430)
        }
        .navigationTitle(store.project.name.isEmpty ? "Untitled Interaction" : store.project.name)
        .safeAreaInset(edge: .bottom, spacing: 0) { statusBar }
        .toolbar { toolbar }
        .focusedSceneValue(\.studioCommandActions, commandActions)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            recentProjects.refresh()
        }
        .fileImporter(
            isPresented: $importingProject,
            allowedContentTypes: [.govonerStudioProject, .json],
            allowsMultipleSelection: false,
            onCompletion: openProject
        )
        .fileExporter(
            isPresented: $exportingProject,
            document: projectDocument,
            contentType: .govonerStudioProject,
            defaultFilename: safeFilename(store.project.name) + ".govonerstudio",
            onCompletion: handleProjectExport
        )
        .fileExporter(
            isPresented: $exportingBash,
            document: bashDocument,
            contentType: .govonerBashScript,
            defaultFilename: store.project.functionName + ".sh",
            onCompletion: handleExport
        )
        .sheet(isPresented: $showBashPreview) {
            BashPreviewView(text: bashPreview, filename: store.project.functionName + ".sh", copy: copyBash, save: saveBash)
        }
        .alert(
            "Govoner Studio",
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            ),
            actions: { Button("OK", role: .cancel) {} },
            message: { Text(errorMessage ?? "Unknown error") }
        )
    }

    @ViewBuilder
    private var inspector: some View {
        if let selection = store.selection,
           let index = store.project.steps.firstIndex(where: { $0.id == selection }) {
            StepInspectorView(step: $store.project.steps[index], index: index)
                .id(selection)
        } else {
            VStack(spacing: 12) {
                Image(systemName: "sidebar.right")
                    .font(.system(size: 34))
                    .foregroundStyle(.secondary)
                Text("Select an interaction")
                    .font(.headline)
                Text("Choose a card in the flow to edit its behavior.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(30)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Menu {
                Button("New Project", action: store.newProject)
                Button("Open Project…") { importingProject = true }
                Menu("Open Recent") {
                    RecentProjectMenuItems(urls: recentProjects.urls, open: openProjectURL, clear: recentProjects.clear)
                }
                Divider()
                Button("Save Project As…", action: saveProject)
            } label: {
                Label("Project", systemImage: "folder")
            }
            .help("New, open, or save a project")
        }

        ToolbarItemGroup(placement: .primaryAction) {
            Menu {
                Button("Preview Script…", action: previewBash)
                Button("Copy Script", action: copyBash)
                Divider()
                Button("Save Script…", action: saveBash)
            } label: {
                Label("Export Bash", systemImage: "square.and.arrow.up")
            }
            .disabled(store.project.steps.isEmpty)
            .help("Preview, copy, or save the Bash script")

            Button(action: runPreview) {
                Label(isStartingPreview ? "Starting…" : "Run Preview", systemImage: "play.fill")
                    .labelStyle(.titleAndIcon)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!canRunPreview)
            .help("Run this flow with The Govoner (⌘R)")
        }
    }

    private var statusBar: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 8) {
                if isStartingPreview {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: store.previewStatus == "Preview failed" ? "exclamationmark.circle" : "checkmark.circle")
                        .foregroundStyle(store.previewStatus == "Preview failed" ? Color.orange : Color.secondary)
                }
                Text(store.previewStatus)
                    .lineLimit(1)
                    .help(store.previewStatus)
                Spacer()
                Text("⌘R to preview")
                    .foregroundStyle(.tertiary)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .background(.bar)
    }

    private var canRunPreview: Bool { !isStartingPreview && !store.project.steps.isEmpty }

    private var commandActions: StudioCommandActions {
        StudioCommandActions(
            newProject: store.newProject,
            openProject: { importingProject = true },
            saveProject: saveProject,
            copyBash: copyBash,
            runPreview: runPreview,
            canRunPreview: canRunPreview,
            recentProjects: recentProjects.urls,
            openRecentProject: openProjectURL,
            clearRecentProjects: recentProjects.clear
        )
    }

    private func openProject(_ result: Result<[URL], Error>) {
        do {
            guard let url = try result.get().first else { return }
            openProjectURL(url)
        } catch {
            errorMessage = "Could not open the project: \(error.localizedDescription)"
        }
    }

    private func openProjectURL(_ url: URL) {
        do {
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            let data = try Data(contentsOf: url)
            store.load(try JSONDecoder().decode(StudioProject.self, from: data))
            recentProjects.record(url)
        } catch {
            errorMessage = "Could not open \(url.lastPathComponent): \(error.localizedDescription)"
        }
    }

    private func handleProjectExport(_ result: Result<URL, Error>) {
        if case .success(let url) = result { recentProjects.record(url) }
        handleExport(result)
    }

    private func saveProject() {
        projectDocument = StudioProjectDocument(project: store.project)
        exportingProject = true
    }

    private func previewBash() {
        do {
            bashPreview = try store.bash()
            showBashPreview = true
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func copyBash() {
        do {
            let text = try store.bash()
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
            bashPreview = text
            store.previewStatus = "Bash copied"
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func saveBash() {
        do {
            bashDocument = BashScriptDocument(text: try store.bash())
            exportingBash = true
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func runPreview() {
        guard canRunPreview else { return }
        do {
            _ = try store.project.validatedDefinitions()
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        isStartingPreview = true
        store.previewStatus = "Starting preview…"
        let project = store.project
        Task {
            defer { isStartingPreview = false }
            do {
                let uuid = try await StudioPreviewRunner.run(project)
                store.previewUUID = uuid
                store.previewStatus = "Preview live · \(uuid.prefix(8))"
            } catch {
                store.previewStatus = "Preview failed"
                errorMessage = error.localizedDescription
            }
        }
    }

    private func handleExport(_ result: Result<URL, Error>) {
        if case .failure(let error) = result {
            errorMessage = "Could not save the file: \(error.localizedDescription)"
        } else {
            store.previewStatus = "Saved"
        }
    }

    private func safeFilename(_ value: String) -> String {
        let invalid = CharacterSet(charactersIn: "/:")
        let components = value.components(separatedBy: invalid).filter { !$0.isEmpty }
        return components.joined(separator: "-").isEmpty ? "Govoner-Interaction" : components.joined(separator: "-")
    }
}
