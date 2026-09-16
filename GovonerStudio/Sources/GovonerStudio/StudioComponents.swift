import GovernorCore
import GovonerStudioCore
import SwiftUI

extension UIType {
    var studioTint: Color {
        switch self {
        case .display: return .blue
        case .choice: return .purple
        case .file: return .orange
        case .media: return .pink
        case .entry: return .teal
        case .confirm: return .green
        }
    }
}

struct InteractionIcon: View {
    let type: UIType
    var size: CGFloat = 36

    var body: some View {
        Image(systemName: type.studioIcon)
            .font(.system(size: size * 0.46, weight: .medium))
            .foregroundStyle(type.studioTint)
            .frame(width: size, height: size)
            .background(type.studioTint.opacity(0.12), in: RoundedRectangle(cornerRadius: size * 0.25))
            .accessibilityHidden(true)
    }
}

struct StudioTextField: View {
    let title: String
    @Binding var text: String
    var prompt = ""
    var monospaced = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField(title, text: $text, prompt: Text(prompt))
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: monospaced ? .monospaced : .default))
                .accessibilityLabel(title)
        }
        .padding(.vertical, 3)
    }
}

struct AddInteractionMenu: View {
    @ObservedObject var store: StudioStore

    var body: some View {
        Menu {
            ForEach(UIType.allCases, id: \.self) { type in
                Button { store.add(type) } label: {
                    Label(type.studioTitle, systemImage: type.studioIcon)
                }
            }
        } label: {
            Label("Add Step", systemImage: "plus")
        }
        .fixedSize()
        .help("Add an interaction to the end of the flow")
    }
}

struct StepActions: View {
    @ObservedObject var store: StudioStore
    let stepID: UUID

    private var index: Int? { store.project.steps.firstIndex { $0.id == stepID } }

    var body: some View {
        Button { store.selection = stepID; store.duplicateSelected() } label: {
            Label("Duplicate Step", systemImage: "plus.square.on.square")
        }
        Divider()
        Button { store.moveStep(stepID, by: -1) } label: {
            Label("Move Up", systemImage: "arrow.up")
        }
        .disabled(index == nil || index == 0)
        Button { store.moveStep(stepID, by: 1) } label: {
            Label("Move Down", systemImage: "arrow.down")
        }
        .disabled(index == nil || index == store.project.steps.count - 1)
        Divider()
        Button(role: .destructive) {
            store.selection = stepID
            store.removeSelected()
        } label: {
            Label("Delete Step", systemImage: "trash")
        }
    }
}
