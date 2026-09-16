import GovernorCore
import GovonerStudioCore
import SwiftUI
import UniformTypeIdentifiers

// A private drag type prevents unrelated text drops from changing the flow.
extension UTType {
    static let studioInteraction = UTType(exportedAs: "com.gnaservices.GovonerStudio.interaction")
}

enum StudioDragItem: Equatable {
    case palette(UIType)
    case step(UUID)

    var itemProvider: NSItemProvider {
        let value: String
        switch self {
        case .palette(let type): value = "type:\(type.rawValue)"
        case .step(let id): value = "step:\(id.uuidString)"
        }
        let provider = NSItemProvider()
        provider.registerDataRepresentation(forTypeIdentifier: UTType.studioInteraction.identifier, visibility: .ownProcess) { completion in
            completion(Data(value.utf8), nil)
            return nil
        }
        return provider
    }
}

struct PaletteView: View {
    @ObservedObject var store: StudioStore
    @ObservedObject var recentProjects: RecentProjectsStore
    @Binding var dragItem: StudioDragItem?
    let openRecent: (URL) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                Label("PROJECT", systemImage: "square.stack.3d.up")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                StudioTextField(title: "Name", text: $store.project.name, prompt: "Untitled Interaction")
                StudioTextField(title: "Bash function", text: $store.project.functionName, monospaced: true)
            }
            .padding(18)

            Divider()

            List {
                Section {
                    if recentProjects.urls.isEmpty {
                        Text("Projects you open or save appear here.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.vertical, 5)
                    } else {
                        ForEach(Array(recentProjects.urls.prefix(3)), id: \.self) { url in
                            Button { openRecent(url) } label: {
                                Label {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(url.deletingPathExtension().lastPathComponent)
                                            .lineLimit(1)
                                        Text((url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                    }
                                } icon: {
                                    Image(systemName: "doc.text")
                                        .foregroundStyle(.secondary)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 4)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .help(url.path)
                        }
                    }
                } header: {
                    HStack {
                        Text("Recent Projects")
                        Spacer()
                        if !recentProjects.urls.isEmpty {
                            Menu {
                                RecentProjectMenuItems(urls: recentProjects.urls, open: openRecent, clear: recentProjects.clear)
                            } label: {
                                Image(systemName: "ellipsis")
                            }
                            .menuStyle(.borderlessButton)
                            .menuIndicator(.hidden)
                            .fixedSize()
                            .accessibilityLabel("Recent project actions")
                        }
                    }
                }

                Section("Interaction Library") {
                    paletteRow(.display)
                    paletteRow(.choice)
                    paletteRow(.entry)
                    paletteRow(.confirm)
                    paletteRow(.file)
                    paletteRow(.media)
                }
            }
            .listStyle(.sidebar)

            Divider()
            Label("Click to add · Drag to arrange", systemImage: "cursorarrow")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(16)
        }
    }

    private func paletteRow(_ type: UIType) -> some View {
        Button { store.add(type) } label: {
            HStack(spacing: 11) {
                Image(systemName: type.studioIcon)
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(type.studioTint)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 3) {
                    Text(type.studioTitle)
                        .fontWeight(.medium)
                    Text(type.studioDescription)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Add a \(type.studioTitle.lowercased()) interaction")
        .accessibilityLabel("Add \(type.studioTitle)")
        .onDrag {
            let item = StudioDragItem.palette(type)
            dragItem = item
            return item.itemProvider
        }
    }
}
