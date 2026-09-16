import GovonerStudioCore
import SwiftUI

struct UGLManagementView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var manager: UGLInstallationManager
    @State private var confirmUninstall = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Image(systemName: "shippingbox.fill")
                    .font(.title2)
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 44, height: 44)
                    .background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 11))
                VStack(alignment: .leading, spacing: 3) {
                    Text("Manage UGL Installation")
                        .font(.title2.weight(.semibold))
                    Text("Install the User Interaction Governor Library independently from this app.")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(20)

            Divider()
            Form {
                Section("Destination") {
                    Picker("Layout", selection: $manager.layout) {
                        ForEach(UGLInstallLayout.allCases) { layout in
                            Text(layout.title).tag(layout)
                        }
                    }
                    .pickerStyle(.segmented)

                    HStack {
                        TextField("Installation path", text: $manager.installPath)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.body, design: .monospaced))
                        Button("Default") { manager.resetPath() }
                    }
                    LabeledContent("Add to PATH") {
                        Text(manager.pathEntry).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    }
                    LabeledContent("Runtime source") {
                        Text(manager.exportRuntimePath).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    }
                    Text(manager.layout == .framework
                         ? "Components are installed under Versions/A. Exports and PATH use Versions/Current so updates do not change script paths."
                         : "Executables are installed in bin; the shared Bash runtime and version metadata are installed in lib/ugl.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Components") {
                    ForEach(manager.statuses) { status in
                        HStack(spacing: 10) {
                            Image(systemName: icon(for: status.comparison))
                                .foregroundStyle(color(for: status.comparison))
                                .frame(width: 18)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(status.component.displayName)
                                Text(status.component.kind.rawValue)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            VStack(alignment: .trailing, spacing: 2) {
                                Text(status.statusText)
                                Text("Installed \(status.installedVersion ?? "—") · Bundled \(status.bundledVersion)")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 3)
                    }
                }

                if let message = manager.message {
                    Section {
                        Label(message, systemImage: message.contains("successfully") || message.contains("removed") ? "checkmark.circle" : "exclamationmark.triangle")
                            .foregroundStyle(message.contains("successfully") || message.contains("removed") ? Color.green : Color.orange)
                    }
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                Button("Refresh", action: manager.refresh)
                Button("Show in Finder", action: manager.revealInstallation)
                    .disabled(!manager.isInstalled)
                Spacer()
                Button("Uninstall…", role: .destructive) { confirmUninstall = true }
                    .disabled(!manager.isInstalled || manager.isWorking)
                Button(manager.actionTitle, action: manager.install)
                    .buttonStyle(.borderedProminent)
                    .disabled(manager.isWorking || !manager.bundledComponentsAvailable || manager.installPath.isEmpty)
            }
            .padding(20)
        }
        .frame(minWidth: 760, idealWidth: 820, minHeight: 650, idealHeight: 720)
        .overlay {
            if manager.isWorking {
                ZStack {
                    Color.black.opacity(0.08)
                    ProgressView("Updating the UGL installation…")
                        .padding(22)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
            }
        }
        .onAppear(perform: manager.refresh)
        .confirmationDialog(
            "Uninstall UGL from this location?",
            isPresented: $confirmUninstall,
            titleVisibility: .visible
        ) {
            Button("Uninstall UGL", role: .destructive, action: manager.uninstall)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes only the managed UGL components shown above. Scripts that source this installation will stop working.")
        }
    }

    private func icon(for comparison: UGLVersionComparison) -> String {
        switch comparison {
        case .current: return "checkmark.circle.fill"
        case .older: return "arrow.down.circle.fill"
        case .newer: return "arrow.up.circle.fill"
        case .unknown: return "questionmark.circle.fill"
        case .missing: return "minus.circle"
        }
    }

    private func color(for comparison: UGLVersionComparison) -> Color {
        switch comparison {
        case .current: return .green
        case .older: return .orange
        case .newer: return .blue
        case .unknown: return .yellow
        case .missing: return .secondary
        }
    }
}
