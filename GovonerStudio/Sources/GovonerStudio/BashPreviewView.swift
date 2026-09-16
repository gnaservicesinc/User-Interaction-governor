import SwiftUI

struct BashPreviewView: View {
    @Environment(\.dismiss) private var dismiss
    let text: String
    let copy: () -> Void
    let save: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Bash Export")
                        .font(.title2.weight(.semibold))
                    Text("Shared runtime, globals, and this interaction function")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding()

            Divider()

            ScrollView([.vertical, .horizontal]) {
                Text(text)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(16)
            }
            .background(.black.opacity(0.04))

            Divider()

            HStack {
                Text("Requires Bash 4+")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Save .sh…", action: save)
                Button("Copy", action: copy)
                    .keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(minWidth: 760, minHeight: 560)
    }
}
