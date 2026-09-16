import GovernorCore
import GovonerStudioCore
import SwiftUI

struct StepInspectorView: View {
    @Binding var step: StudioStep
    let index: Int

    var body: some View {
        Form {
            Section {
                HStack(spacing: 11) {
                    Image(systemName: step.uiType.studioIcon)
                        .font(.title2)
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 32)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Step \(index + 1)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(step.uiType.studioTitle)
                            .font(.headline)
                    }
                }
            }

            Section("Window") {
                TextField("Title (optional)", text: $step.title)
            }

            switch step.uiType {
            case .display: displayFields
            case .choice: choiceFields
            case .file: fileFields
            case .media: mediaFields
            case .entry: entryFields
            case .confirm: confirmFields
            }

            Section("Result") {
                LabeledContent("Outcome key") {
                    Text("$uuid:\(index)")
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                }
                LabeledContent("Primary value") {
                    Text(step.primaryResultField ?? "none")
                        .font(.system(.caption, design: .monospaced))
                }
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private var displayFields: some View {
        Section("Message") {
            MultilineField(text: $step.message, prompt: "Message shown to the user")
            TextField("Button label (optional)", text: $step.displayButton)
        }
    }

    @ViewBuilder
    private var choiceFields: some View {
        Section("Question") {
            MultilineField(text: $step.message, prompt: "What should the user choose?")
        }
        Section("Buttons") {
            StringListEditor(values: $step.buttons, defaultValue: "Option", minimumCount: 2)
        }
    }

    @ViewBuilder
    private var fileFields: some View {
        Section("Picker") {
            Picker("Mode", selection: $step.fileMode) {
                Text("Open").tag("open")
                Text("Save").tag("save")
            }
            .pickerStyle(.segmented)
            TextField("Starting directory (optional)", text: $step.directory)
            if step.fileMode == "save" {
                TextField("Suggested filename (optional)", text: $step.filename)
            }
        }
        Section("Filename filters") {
            StringListEditor(values: $step.filters, defaultValue: "*", minimumCount: 1)
        }
    }

    @ViewBuilder
    private var mediaFields: some View {
        Section("Media") {
            Picker("Type", selection: $step.mediaType) {
                Text("Image").tag("image")
                Text("Audio").tag("audio")
                Text("Video").tag("video")
            }
            TextField("File path", text: $step.mediaPath)
        }
        if step.mediaType == "image" {
            Section("Presentation") {
                LabeledContent("Auto-close seconds") {
                    TextField("0", value: $step.autoClose, format: .number)
                        .frame(width: 80)
                }
                Text("Use 0 to keep the image open until dismissed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } else {
            Section("Playback") {
                LabeledContent("Volume") {
                    HStack {
                        Slider(value: volumeBinding, in: 0...100, step: 1)
                        Text("\(step.volume)%")
                            .font(.caption.monospacedDigit())
                            .frame(width: 38, alignment: .trailing)
                    }
                }
                Toggle("Loop forever", isOn: $step.forever)
                if !step.forever {
                    Stepper("Plays: \(step.plays)", value: $step.plays, in: 1...100)
                }
            }
        }
    }

    @ViewBuilder
    private var entryFields: some View {
        Section("Entry") {
            Picker("Type", selection: $step.entryType) {
                Text("Text").tag("text")
                Text("Multiple lines").tag("multiline")
                Text("Number").tag("number")
            }
            TextField("Prompt (optional)", text: $step.message)
            TextField("Default value (optional)", text: $step.defaultValue)
            Toggle("Required", isOn: $step.required)
            LabeledContent("Maximum length") {
                TextField("0", value: $step.maxLength, format: .number)
                    .frame(width: 80)
            }
            Text("Use 0 for no length limit.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        if step.entryType == "number" {
            Section("Number range") {
                TextField("Minimum (optional)", text: $step.minimum)
                TextField("Maximum (optional)", text: $step.maximum)
            }
        }
    }

    @ViewBuilder
    private var confirmFields: some View {
        Section("Confirmation") {
            MultilineField(text: $step.message, prompt: "What should the user confirm?")
            TextField("Confirm label", text: $step.confirmLabel)
            TextField("Cancel label", text: $step.cancelLabel)
        }
        Section {
            Text("Cancel stops the remaining flow. A normal Choice continues regardless of the selected label.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var volumeBinding: Binding<Double> {
        Binding(
            get: { Double(step.volume) },
            set: { step.volume = Int($0) }
        )
    }
}

private struct MultilineField: View {
    @Binding var text: String
    let prompt: String

    var body: some View {
        ZStack(alignment: .topLeading) {
            if text.isEmpty {
                Text(prompt)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 8)
            }
            TextEditor(text: $text)
                .font(.body)
                .scrollContentBackground(.hidden)
        }
        .frame(minHeight: 74)
        .padding(3)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 6))
    }
}

private struct StringListEditor: View {
    @Binding var values: [String]
    let defaultValue: String
    let minimumCount: Int

    var body: some View {
        ForEach(values.indices, id: \.self) { index in
            HStack {
                TextField("Value", text: $values[index])
                Button(role: .destructive) {
                    values.remove(at: index)
                } label: {
                    Image(systemName: "minus.circle")
                }
                .buttonStyle(.borderless)
                .disabled(values.count <= minimumCount)
            }
        }
        Button {
            values.append(defaultValue)
        } label: {
            Label("Add", systemImage: "plus")
        }
        .buttonStyle(.borderless)
    }
}
