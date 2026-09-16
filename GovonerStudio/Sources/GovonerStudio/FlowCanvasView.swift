import GovonerStudioCore
import SwiftUI
import UniformTypeIdentifiers

struct FlowCanvasView: View {
    @ObservedObject var store: StudioStore
    @Binding var dragItem: StudioDragItem?
    @State private var isDropTarget = false

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                header

                if store.project.steps.isEmpty {
                    emptyState
                        .padding(.top, 60)
                        .onDrop(
                            of: [.text],
                            delegate: FlowEndDropDelegate(store: store, dragItem: $dragItem, isTargeted: $isDropTarget)
                        )
                } else {
                    ForEach(Array(store.project.steps.enumerated()), id: \.element.id) { index, step in
                        if index > 0 { connector }
                        FlowStepCard(
                            step: step,
                            index: index,
                            selected: store.selection == step.id,
                            select: { store.selection = step.id },
                            beginDrag: { dragItem = .step(step.id) }
                        )
                        .onDrop(
                            of: [.text],
                            delegate: FlowCardDropDelegate(
                                targetID: step.id,
                                store: store,
                                dragItem: $dragItem
                            )
                        )
                    }

                    connector
                    endCap
                        .onDrop(
                            of: [.text],
                            delegate: FlowEndDropDelegate(store: store, dragItem: $dragItem, isTargeted: $isDropTarget)
                        )
                }
            }
            .frame(maxWidth: 620)
            .padding(28)
            .frame(maxWidth: .infinity)
        }
        .background(.ultraThinMaterial)
        .overlay {
            if isDropTarget {
                RoundedRectangle(cornerRadius: 14)
                    .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [7]))
                    .padding(10)
                    .allowsHitTesting(false)
            }
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Interaction Flow")
                    .font(.title2.weight(.semibold))
                Text("Drag interactions here and reorder them into a sequence.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text("\(store.project.steps.count) step\(store.project.steps.count == 1 ? "" : "s")")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.bottom, 24)
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "point.3.connected.trianglepath.dotted")
                .font(.system(size: 42))
                .foregroundStyle(Color.accentColor)
            Text("Build your first interaction")
                .font(.headline)
            Text("Drag a type from the palette, or click one to add it.")
                .foregroundStyle(.secondary)
        }
        .padding(36)
        .frame(maxWidth: .infinity)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
    }

    private var connector: some View {
        VStack(spacing: 0) {
            Rectangle().fill(.tertiary).frame(width: 2, height: 18)
            Image(systemName: "chevron.down")
                .font(.caption2.weight(.bold))
                .foregroundStyle(.tertiary)
            Rectangle().fill(.tertiary).frame(width: 2, height: 8)
        }
    }

    private var endCap: some View {
        Label("Result", systemImage: "flag.checkered")
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(.quaternary.opacity(0.5), in: Capsule())
    }
}

private struct FlowStepCard: View {
    let step: StudioStep
    let index: Int
    let selected: Bool
    let select: () -> Void
    let beginDrag: () -> Void

    var body: some View {
        Button(action: select) {
            HStack(spacing: 14) {
                Image(systemName: "line.3.horizontal")
                    .foregroundStyle(.tertiary)
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color.accentColor.opacity(0.14))
                    Image(systemName: step.uiType.studioIcon)
                        .font(.title2)
                        .foregroundStyle(Color.accentColor)
                }
                .frame(width: 46, height: 46)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 7) {
                        Text("\(index + 1)")
                            .font(.caption2.monospacedDigit().weight(.bold))
                            .foregroundStyle(.secondary)
                        Text(step.uiType.studioTitle)
                            .font(.headline)
                    }
                    Text(step.summary)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .foregroundStyle(.tertiary)
            }
            .padding(14)
            .contentShape(Rectangle())
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 13))
            .overlay {
                RoundedRectangle(cornerRadius: 13)
                    .stroke(selected ? Color.accentColor : Color.secondary.opacity(0.16), lineWidth: selected ? 2 : 1)
            }
        }
        .buttonStyle(.plain)
        .onDrag {
            beginDrag()
            return NSItemProvider(object: "step:\(step.id.uuidString)" as NSString)
        }
    }
}

private struct FlowCardDropDelegate: DropDelegate {
    let targetID: UUID
    @ObservedObject var store: StudioStore
    @Binding var dragItem: StudioDragItem?

    func dropEntered(info: DropInfo) {
        switch dragItem {
        case .palette(let type):
            let index = store.project.steps.firstIndex(where: { $0.id == targetID }) ?? store.project.steps.count
            dragItem = .step(store.add(type, at: index))
        case .step(let id):
            store.move(stepID: id, before: targetID)
        case .none:
            break
        }
    }

    func performDrop(info: DropInfo) -> Bool {
        dragItem = nil
        return true
    }

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }
}

private struct FlowEndDropDelegate: DropDelegate {
    @ObservedObject var store: StudioStore
    @Binding var dragItem: StudioDragItem?
    @Binding var isTargeted: Bool

    func validateDrop(info: DropInfo) -> Bool { true }

    func dropEntered(info: DropInfo) { isTargeted = true }
    func dropExited(info: DropInfo) { isTargeted = false }

    func performDrop(info: DropInfo) -> Bool {
        switch dragItem {
        case .palette(let type): _ = store.add(type)
        case .step(let id): store.moveToEnd(stepID: id)
        case .none: break
        }
        dragItem = nil
        isTargeted = false
        return true
    }

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }
}
