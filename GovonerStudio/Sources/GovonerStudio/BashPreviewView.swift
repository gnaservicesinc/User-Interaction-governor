import SwiftUI

struct BashPreviewView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false
    let text: String
    let filename: String
    let copy: () -> Void
    let save: () -> Void

    private var lineCount: Int { text.components(separatedBy: "\n").count }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Image(systemName: "terminal")
                    .font(.title2)
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 44, height: 44)
                    .background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 11))
                VStack(alignment: .leading, spacing: 4) {
                    Text("Bash Export")
                        .font(.title2.weight(.semibold))
                    Text(filename)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(20)

            Divider()
            ScrollView([.vertical, .horizontal]) {
                HStack(alignment: .top, spacing: 16) {
                    Text((1...lineCount).map(String.init).joined(separator: "\n"))
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.trailing)
                        .accessibilityHidden(true)
                    Text(text)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                .font(.system(size: 12, design: .monospaced))
                .lineSpacing(4)
                .fixedSize(horizontal: true, vertical: false)
                .padding(20)
            }
            .background(.background)
            Divider()

            HStack(spacing: 12) {
                Label("Bash 4 or newer", systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("· \(lineCount) lines")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Spacer()
                Button("Save Script…", action: save)
                Button {
                    copy()
                    copied = true
                } label: {
                    Label(copied ? "Copied" : "Copy Script", systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
            .padding(20)
        }
        .frame(minWidth: 760, idealWidth: 840, minHeight: 560, idealHeight: 640)
    }
}
