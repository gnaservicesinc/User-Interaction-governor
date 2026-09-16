import GovernorCore
import GovonerStudioCore
import SwiftUI
import UniformTypeIdentifiers

struct StepInspectorView: View {
    @Binding var step: StudioStep
    let index: Int
    @State private var showingResult = false
    @State private var importingPath = false
    @State private var importingDirectory = false
    @State private var importError: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                InteractionIcon(type: step.uiType, size: 38)
                VStack(alignment: .leading, spacing: 4) {
                    Text("STEP \(String(format: "%02d", index + 1))")
                        .font(.system(size: 10, weight: .semibold))
                        .tracking(0.8)
                        .foregroundStyle(.secondary)
                    Text("\(step.uiType.studioTitle) Inspector")
                        .font(.headline)
                }
                Spacer(minLength: 0)
            }
            .padding(20)
            Divider()

            Form {
                Section("Window") {
                    StudioTextField(title: "Title", text: $step.title, prompt: "Optional window title")
                }

                switch step.uiType {
                case .display: displayFields
                case .choice: choiceFields
                case .file: fileFields
                case .media: mediaFields
                case .entry: entryFields
                case .confirm: confirmFields
                }

                Section {
                    DisclosureGroup("Bash result", isExpanded: $showingResult) {
                        LabeledContent("Outcome key") {
                            Text("$uuid:\(index)")
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                        }
                        LabeledContent("Primary value") {
                            Text(step.primaryResultField ?? "none")
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                        }
                    }
                    .font(.caption)
                }
            }
            .formStyle(.grouped)
        }
        .fileImporter(isPresented: $importingPath, allowedContentTypes: importTypes) { result in
            switch result {
            case .success(let url):
                if importingDirectory { step.directory = url.path }
                else { step.mediaPath = url.path }
            case .failure(let error): importError = error.localizedDescription
            }
        }
        .alert("Could not select a path", isPresented: Binding(
            get: { importError != nil },
            set: { if !$0 { importError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(importError ?? "")
        }
    }

    @ViewBuilder
    private var displayFields: some View {
        Section("Message") {
            MultilineField(text: $step.message, prompt: "Message shown to the user")
            StudioTextField(title: "Button label", text: $step.displayButton, prompt: "OK")
        }
    }

    @ViewBuilder
    private var choiceFields: some View {
        Section("Question") {
            MultilineField(text: $step.message, prompt: "What should the user choose?")
        }
        Section {
            StringListEditor(values: $step.buttons, defaultValue: "Option", minimumCount: 2, maximumCount: DefinitionValidator.maximumChoiceButtons, itemTitle: "Button", addTitle: "Add Button")
        } header: {
            Text("Buttons")
        } footer: {
            Text("Buttons appear in this order. Any choice continues the flow.")
        }
    }

    @ViewBuilder
    private var fileFields: some View {
        Section("File picker") {
            Picker("Mode", selection: $step.fileMode) {
                Text("Open").tag("open")
                Text("Save").tag("save")
            }
            .pickerStyle(.segmented)
            StudioTextField(title: "Starting directory", text: $step.directory, prompt: "Use the default location")
            Button("Choose Folder…") {
                importingDirectory = true
                importingPath = true
            }
            if step.fileMode == "save" {
                StudioTextField(title: "Suggested filename", text: $step.filename, prompt: "Optional filename")
            }
        }
        Section {
            StringListEditor(values: $step.filters, defaultValue: "*", minimumCount: 1, itemTitle: "Filter", addTitle: "Add Filter")
        } header: {
            Text("Filename filters")
        } footer: {
            Text("Use * for all files, or a pattern such as *.png.")
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
            StudioTextField(title: "File path", text: $step.mediaPath, prompt: "Choose a media file")
            Button("Choose File…") {
                importingDirectory = false
                importingPath = true
            }
        }
        if step.mediaType == "image" {
            Section {
                LabeledContent("Close after") {
                    TextField("Seconds", value: $step.autoClose, format: .number)
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 64)
                        .accessibilityLabel("Auto-close seconds")
                    Text("sec").foregroundStyle(.secondary)
                }
            } header: {
                Text("Presentation")
            } footer: {
                Text("Set to 0 to keep the image open until dismissed.")
            }
        } else {
            Section("Playback") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Volume")
                        Spacer()
                        Text("\(step.volume)%").monospacedDigit().foregroundStyle(.secondary)
                    }
                    Slider(value: volumeBinding, in: 0...100, step: 1)
                        .accessibilityLabel("Volume")
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
        Section("Input") {
            Picker("Type", selection: $step.entryType) {
                Text("Text").tag("text")
                Text("Multiple lines").tag("multiline")
                Text("Number").tag("number")
            }
            StudioTextField(title: "Prompt", text: $step.message, prompt: "What should the user enter?")
            StudioTextField(title: "Default value", text: $step.defaultValue, prompt: "Optional starting value")
            Toggle("Required", isOn: $step.required)
        }
        Section {
            LabeledContent("Maximum length") {
                TextField("Unlimited", value: $step.maxLength, format: .number)
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 70)
                    .accessibilityLabel("Maximum length")
            }
        } header: {
            Text("Limits")
        } footer: {
            Text("Set to 0 for no length limit.")
        }
        if step.entryType == "number" {
            Section("Number range") {
                StudioTextField(title: "Minimum", text: $step.minimum, prompt: "No minimum")
                StudioTextField(title: "Maximum", text: $step.maximum, prompt: "No maximum")
            }
        }
    }

    @ViewBuilder
    private var confirmFields: some View {
        Section("Question") {
            MultilineField(text: $step.message, prompt: "What should the user confirm?")
        }
        Section {
            StudioTextField(title: "Confirm label", text: $step.confirmLabel, prompt: "Continue")
            StudioTextField(title: "Cancel label", text: $step.cancelLabel, prompt: "Cancel")
        } header: {
            Text("Buttons")
        } footer: {
            Label("Cancel stops the remaining flow.", systemImage: "info.circle")
        }
    }

    private var importTypes: [UTType] {
        if importingDirectory { return [.folder] }
        switch step.mediaType {
        case "audio": return [.audio]
        case "video": return [.movie]
        default: return [.image]
        }
    }

    private var volumeBinding: Binding<Double> {
        Binding(get: { Double(step.volume) }, set: { step.volume = Int($0) })
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
                    .padding(.horizontal, 6)
                    .padding(.vertical, 8)
                    .allowsHitTesting(false)
            }
            TextEditor(text: $text)
                .font(.body)
                .scrollContentBackground(.hidden)
                .accessibilityLabel(prompt)
        }
        .frame(height: 110)
        .padding(5)
        .background(.background, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.secondary.opacity(0.18)))
    }
}

private struct StringListEditor: View {
    @Binding var values: [String]
    let defaultValue: String
    let minimumCount: Int
    var maximumCount = Int.max
    let itemTitle: String
    let addTitle: String

    var body: some View {
        ForEach(values.indices, id: \.self) { index in
            HStack(spacing: 8) {
                Text("\(index + 1)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
                TextField(itemTitle, text: $values[index])
                    .labelsHidden()
                    .multilineTextAlignment(.leading)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("\(itemTitle) \(index + 1)")
                Button(role: .destructive) { values.remove(at: index) } label: {
                    Image(systemName: "minus.circle")
                }
                .buttonStyle(.borderless)
                .disabled(values.count <= minimumCount)
                .help("Remove \(itemTitle.lowercased()) \(index + 1)")
                .accessibilityLabel("Remove \(itemTitle.lowercased()) \(index + 1)")
            }
        }
        Button { values.append(defaultValue) } label: {
            Label(addTitle, systemImage: "plus")
        }
        .buttonStyle(.borderless)
        .disabled(values.count >= maximumCount)
    }
}
