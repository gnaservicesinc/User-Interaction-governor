import GovonerStudioCore
import SwiftUI

struct FlowStepCard: View {
    @ObservedObject var store: StudioStore
    let step: StudioStep
    let index: Int
    let selected: Bool
    let beginDrag: () -> Void
    @State private var hovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Button { store.selection = step.id } label: {
                    HStack(spacing: 12) {
                        InteractionIcon(type: step.uiType, size: 40)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("STEP \(String(format: "%02d", index + 1)) · \(step.uiType.studioTitle.uppercased())")
                                .font(.system(size: 10, weight: .semibold))
                                .tracking(0.7)
                                .foregroundStyle(.secondary)
                            Text(step.title.isEmpty ? step.uiType.studioTitle : step.title)
                                .font(.headline)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Step \(index + 1), \(step.uiType.studioTitle), \(step.title)")
                .accessibilityAddTraits(selected ? [.isSelected] : [])
                Menu { StepActions(store: store, stepID: step.id) } label: {
                    Image(systemName: "ellipsis")
                        .frame(width: 20, height: 24)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Step actions")
                .accessibilityLabel("Actions for step \(index + 1)")
            }
            .padding(16)

            Button { store.selection = step.id } label: {
                VStack(alignment: .leading, spacing: 14) {
                    Text(step.summary)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    HStack(spacing: 6) {
                        ForEach(Array(details.prefix(3).enumerated()), id: \.offset) { _, detail in
                            Text(detail)
                                .font(.caption)
                                .lineLimit(1)
                                .padding(.horizontal, 9)
                                .padding(.vertical, 4)
                                .background(step.uiType.studioTint.opacity(0.08), in: RoundedRectangle(cornerRadius: 5))
                        }
                        if details.count > 3 {
                            Text("+\(details.count - 3)").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "line.3.horizontal")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .accessibilityHidden(true)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(step.summary)
            .accessibilityHint("Select to edit this interaction")
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(selected ? Color.accentColor : Color.secondary.opacity(hovered ? 0.4 : 0.2), lineWidth: selected ? 2 : 1)
                .allowsHitTesting(false)
        }
        .shadow(color: .black.opacity(selected ? 0.07 : 0.03), radius: 8, y: 3)
        .onHover { hovered = $0 }
        .contextMenu { StepActions(store: store, stepID: step.id) }
        .onDrag {
            beginDrag()
            return StudioDragItem.step(step.id).itemProvider
        }
    }

    private var details: [String] {
        switch step.uiType {
        case .display: return [step.displayButton.isEmpty ? "OK" : step.displayButton]
        case .choice: return step.buttons
        case .file: return [step.fileMode == "save" ? "Save dialog" : "Open dialog"] + step.filters
        case .media: return [step.mediaType.capitalized, step.mediaType == "image" ? (step.autoClose > 0 ? "\(step.autoClose.formatted())s" : "Dismiss to continue") : (step.forever ? "Looping" : "\(step.plays) play\(step.plays == 1 ? "" : "s")")]
        case .entry: return [step.entryType == "multiline" ? "Multiple lines" : step.entryType.capitalized, step.required ? "Required" : "Optional"]
        case .confirm: return [step.confirmLabel.isEmpty ? "Continue" : step.confirmLabel, step.cancelLabel.isEmpty ? "Cancel" : step.cancelLabel]
        }
    }
}
