import GovonerStudioCore
import SwiftUI
import UniformTypeIdentifiers

struct FlowCanvasView: View {
    @ObservedObject var store: StudioStore
    @Binding var dragItem: StudioDragItem?
    @State private var dropTarget: UUID?
    @State private var isEndTarget = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 0) {
                        if store.project.steps.isEmpty {
                            emptyState
                        } else {
                            endpoint("Start", icon: "play.fill")
                            connector
                            ForEach(Array(store.project.steps.enumerated()), id: \.element.id) { index, step in
                                FlowStepCard(
                                    store: store,
                                    step: step,
                                    index: index,
                                    selected: store.selection == step.id,
                                    beginDrag: { dragItem = .step(step.id) }
                                )
                                .id(step.id)
                                .overlay(alignment: .top) {
                                    if dropTarget == step.id {
                                        Capsule().fill(Color.accentColor).frame(height: 3).offset(y: -8)
                                    }
                                }
                                .onDrop(
                                    of: [.studioInteraction],
                                    delegate: FlowDropDelegate(
                                        targetID: step.id,
                                        store: store,
                                        dragItem: $dragItem,
                                        dropTarget: $dropTarget,
                                        isEndTarget: $isEndTarget
                                    )
                                )
                                connector
                            }
                            endpoint("Finish · Collect results", icon: "checkmark.circle")
                                .padding(.bottom, 24)
                            addStepTarget
                        }
                    }
                    .frame(maxWidth: 580)
                    .padding(28)
                    .frame(maxWidth: .infinity)
                }
                .onChange(of: store.selection) { selection in
                    guard let selection else { return }
                    withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
                        proxy.scrollTo(selection)
                    }
                }
            }
            .background { CanvasGrid().allowsHitTesting(false) }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 9) {
                    Text("Interaction Flow")
                        .font(.title2.weight(.semibold))
                    Text("\(store.project.steps.count)")
                        .font(.caption.monospacedDigit().weight(.medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(.quaternary, in: Capsule())
                        .accessibilityLabel("\(store.project.steps.count) steps")
                }
                Text("A sequence of small, useful interactions.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            AddInteractionMenu(store: store)
                .menuStyle(.borderlessButton)
        }
        .padding(20)
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "square.stack.3d.up")
                .font(.system(size: 38, weight: .light))
                .foregroundStyle(Color.accentColor)
                .frame(width: 80, height: 80)
                .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 22))
            Text("Every flow starts with a step")
                .font(.title3.weight(.semibold))
            Text("Add a message, ask a question, or collect a file.\nYour interactions run in order, from top to bottom.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            AddInteractionMenu(store: store)
        }
        .padding(.vertical, 50)
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .overlay {
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(isEndTarget ? Color.accentColor : Color.secondary.opacity(0.2), style: StrokeStyle(lineWidth: 1, dash: [5]))
        }
        .onDrop(of: [.studioInteraction], delegate: endDropDelegate)
    }

    private var connector: some View {
        Rectangle()
            .fill(Color.secondary.opacity(0.22))
            .frame(width: 1, height: 26)
            .accessibilityHidden(true)
    }

    private func endpoint(_ title: String, icon: String) -> some View {
        Label(title, systemImage: icon)
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(Color.secondary.opacity(0.15)))
    }

    private var addStepTarget: some View {
        HStack {
            AddInteractionMenu(store: store)
                .menuStyle(.borderlessButton)
            Spacer()
            Text("or drop here")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .background(isEndTarget ? Color.accentColor.opacity(0.08) : Color.clear)
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(isEndTarget ? Color.accentColor : Color.secondary.opacity(0.25), style: StrokeStyle(lineWidth: 1, dash: [5]))
        }
        .contentShape(Rectangle())
        .onDrop(of: [.studioInteraction], delegate: endDropDelegate)
    }

    private var endDropDelegate: FlowDropDelegate {
        FlowDropDelegate(targetID: nil, store: store, dragItem: $dragItem, dropTarget: $dropTarget, isEndTarget: $isEndTarget)
    }
}

private struct CanvasGrid: View {
    var body: some View {
        Canvas { context, size in
            var dots = Path()
            for x in stride(from: 12.0, through: size.width, by: 24) {
                for y in stride(from: 12.0, through: size.height, by: 24) {
                    dots.addEllipse(in: CGRect(x: x, y: y, width: 1.5, height: 1.5))
                }
            }
            context.fill(dots, with: .color(.secondary.opacity(0.15)))
        }
        .accessibilityHidden(true)
    }
}

private struct FlowDropDelegate: DropDelegate {
    let targetID: UUID?
    @ObservedObject var store: StudioStore
    @Binding var dragItem: StudioDragItem?
    @Binding var dropTarget: UUID?
    @Binding var isEndTarget: Bool

    func validateDrop(info: DropInfo) -> Bool {
        dragItem != nil && info.hasItemsConforming(to: [.studioInteraction])
    }

    func dropEntered(info: DropInfo) {
        guard validateDrop(info: info) else { return }
        dropTarget = targetID
        isEndTarget = targetID == nil
    }

    func dropExited(info: DropInfo) {
        if dropTarget == targetID { dropTarget = nil }
        if targetID == nil { isEndTarget = false }
    }

    func performDrop(info: DropInfo) -> Bool {
        guard validateDrop(info: info), let item = dragItem else { return false }
        // Commit on drop so hovering or cancelling never changes the project.
        switch item {
        case .palette(let type):
            let index = targetID.flatMap { id in store.project.steps.firstIndex { $0.id == id } }
            store.add(type, at: index)
        case .step(let id):
            if let targetID { store.move(stepID: id, before: targetID) }
            else { store.moveToEnd(stepID: id) }
            store.selection = id
        }
        dragItem = nil
        dropTarget = nil
        isEndTarget = false
        return true
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: dragItem == nil ? .forbidden : .move)
    }
}
