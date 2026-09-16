import AppKit
import GovonerStudioCore
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @StateObject private var store = StudioStore()
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

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            PaletteView(store: store, dragItem: $dragItem)
                .navigationSplitViewColumnWidth(min: 220, ideal: 250, max: 300)
        } content: {
            FlowCanvasView(store: store, dragItem: $dragItem)
                .navigationSplitViewColumnWidth(min: 390, ideal: 560)
        } detail: {
            inspector
                .navigationSplitViewColumnWidth(min: 300, ideal: 340, max: 430)
        }
        .navigationTitle(store.project.name)
        .toolbar { toolbar }
        .focusedSceneValue(\.studioCommandActions, commandActions)
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
            onCompletion: handleExport
        )
        .fileExporter(
            isPresented: $exportingBash,
            document: bashDocument,
            contentType: .govonerBashScript,
            defaultFilename: store.project.functionName + ".sh",
            onCompletion: handleExport
        )
        .sheet(isPresented: $showBashPreview) {
            BashPreviewView(text: bashPreview, copy: copyBash, save: saveBash)
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
        ToolbarItemGroup(placement: .primaryAction) {
            Button(action: runPreview) {
                Label("Run Preview", systemImage: "play.fill")
            }
            .help("Run this flow with The Govoner")

            Button(action: previewBash) {
                Label("Bash", systemImage: "chevron.left.forwardslash.chevron.right")
            }
            .help("Preview the generated Bash functions")

            Button(action: copyBash) {
                Label("Copy", systemImage: "doc.on.doc")
            }
            .help("Copy the Bash functions")
        }

        ToolbarItemGroup(placement: .secondaryAction) {
            Button(action: store.duplicateSelected) {
                Label("Duplicate", systemImage: "plus.square.on.square")
            }
            .disabled(store.selection == nil)

            Button(role: .destructive, action: store.removeSelected) {
                Label("Delete", systemImage: "trash")
            }
            .disabled(store.selection == nil)
        }

        ToolbarItem(placement: .status) {
            HStack(spacing: 6) {
                Circle()
                    .fill(store.previewStatus == "Ready" ? Color.secondary : Color.accentColor)
                    .frame(width: 7, height: 7)
                Text(store.previewStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    private var commandActions: StudioCommandActions {
        StudioCommandActions(
            newProject: store.newProject,
            openProject: { importingProject = true },
            saveProject: saveProject,
            copyBash: copyBash,
            runPreview: runPreview
        )
    }

    private func openProject(_ result: Result<[URL], Error>) {
        do {
            guard let url = try result.get().first else { return }
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            let data = try Data(contentsOf: url)
            store.load(try JSONDecoder().decode(StudioProject.self, from: data))
        } catch {
            errorMessage = "Could not open the project: \(error.localizedDescription)"
        }
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
        do {
            _ = try store.project.validatedDefinitions()
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        store.previewStatus = "Starting preview…"
        let project = store.project
        Task {
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
