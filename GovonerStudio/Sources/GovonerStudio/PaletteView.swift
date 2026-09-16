import GovernorCore
import GovonerStudioCore
import SwiftUI

enum StudioDragItem: Equatable {
    case palette(UIType)
    case step(UUID)
}

struct PaletteView: View {
    @ObservedObject var store: StudioStore
    @Binding var dragItem: StudioDragItem?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                Section("Project") {
                    TextField("Project name", text: $store.project.name)
                    TextField("Bash function", text: $store.project.functionName)
                        .font(.system(.body, design: .monospaced))
                }
            }
            .formStyle(.grouped)
            .frame(height: 158)

            Divider()

            HStack {
                Text("INTERACTIONS")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("DRAG TO FLOW")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(UIType.allCases, id: \.self) { type in
                        paletteRow(type)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 12)
            }

            Divider()
            Label("Flows run from top to bottom", systemImage: "arrow.down")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(12)
        }
    }

    private func paletteRow(_ type: UIType) -> some View {
        Button {
            _ = store.add(type)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: type.studioIcon)
                    .font(.title3)
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 26)
                VStack(alignment: .leading, spacing: 2) {
                    Text(type.studioTitle)
                        .fontWeight(.medium)
                    Text(type.studioDescription)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer()
                Image(systemName: "plus.circle")
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
            .padding(10)
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 9))
        }
        .buttonStyle(.plain)
        .onDrag {
            dragItem = .palette(type)
            return NSItemProvider(object: "type:\(type.rawValue)" as NSString)
        }
    }
}
