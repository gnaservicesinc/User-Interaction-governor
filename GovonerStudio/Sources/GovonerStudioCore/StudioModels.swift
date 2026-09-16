import Foundation
import GovernorCore

public struct StudioProject: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var name: String
    public var functionName: String
    public var steps: [StudioStep]

    public init(
        schemaVersion: Int = 1,
        name: String = "Untitled Interaction",
        functionName: String = "run_govoner_interaction",
        steps: [StudioStep] = [StudioStep.template(for: .display)]
    ) {
        self.schemaVersion = schemaVersion
        self.name = name
        self.functionName = functionName
        self.steps = steps
    }

    public static var starter: StudioProject { StudioProject() }

    public func validatedDefinitions() throws -> [StepDefinition] {
        guard schemaVersion == 1 else {
            throw StudioValidationError("Unsupported Studio project version \(schemaVersion).")
        }
        guard !steps.isEmpty else {
            throw StudioValidationError("Add at least one interaction to the flow.")
        }
        guard steps.count <= DefinitionValidator.maximumSteps else {
            throw StudioValidationError("A flow can contain at most \(DefinitionValidator.maximumSteps) interactions.")
        }
        let definitions = try steps.map { try $0.definition() }
        do {
            try DefinitionValidator.validate(InteractionDefinition(steps: definitions))
        } catch let error as StructuredError {
            throw StudioValidationError(error.message)
        }
        return definitions
    }
}

public struct StudioStep: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var uiType: UIType
    public var title: String
    public var message: String
    public var displayButton: String
    public var buttons: [String]
    public var fileMode: String
    public var directory: String
    public var filters: [String]
    public var filename: String
    public var mediaType: String
    public var mediaPath: String
    public var volume: Int
    public var plays: Int
    public var forever: Bool
    public var autoClose: Double
    public var entryType: String
    public var defaultValue: String
    public var required: Bool
    public var maxLength: Int
    public var minimum: String
    public var maximum: String
    public var confirmLabel: String
    public var cancelLabel: String

    public init(
        id: UUID = UUID(),
        uiType: UIType,
        title: String = "",
        message: String = "",
        displayButton: String = "",
        buttons: [String] = [],
        fileMode: String = "open",
        directory: String = "",
        filters: [String] = ["*"],
        filename: String = "",
        mediaType: String = "image",
        mediaPath: String = "",
        volume: Int = 80,
        plays: Int = 1,
        forever: Bool = false,
        autoClose: Double = 0,
        entryType: String = "text",
        defaultValue: String = "",
        required: Bool = false,
        maxLength: Int = 0,
        minimum: String = "",
        maximum: String = "",
        confirmLabel: String = "Continue",
        cancelLabel: String = "Cancel"
    ) {
        self.id = id
        self.uiType = uiType
        self.title = title
        self.message = message
        self.displayButton = displayButton
        self.buttons = buttons
        self.fileMode = fileMode
        self.directory = directory
        self.filters = filters
        self.filename = filename
        self.mediaType = mediaType
        self.mediaPath = mediaPath
        self.volume = volume
        self.plays = plays
        self.forever = forever
        self.autoClose = autoClose
        self.entryType = entryType
        self.defaultValue = defaultValue
        self.required = required
        self.maxLength = maxLength
        self.minimum = minimum
        self.maximum = maximum
        self.confirmLabel = confirmLabel
        self.cancelLabel = cancelLabel
    }

    public static func template(for type: UIType) -> StudioStep {
        switch type {
        case .display:
            return StudioStep(uiType: type, message: "The Govoner is ready.", displayButton: "OK")
        case .choice:
            return StudioStep(uiType: type, message: "Choose an option.", buttons: ["Yes", "No"])
        case .file:
            return StudioStep(uiType: type, fileMode: "open", filters: ["*"])
        case .media:
            return StudioStep(uiType: type, mediaType: "image", volume: 80, plays: 1)
        case .entry:
            return StudioStep(uiType: type, message: "Enter a value.", entryType: "text")
        case .confirm:
            return StudioStep(
                uiType: type,
                message: "Would you like to continue?",
                confirmLabel: "Continue",
                cancelLabel: "Cancel"
            )
        }
    }

    public var summary: String {
        switch uiType {
        case .display, .choice, .entry, .confirm:
            return message.isEmpty ? "Configure in the inspector" : message
        case .file:
            return fileMode == "save" ? "Save a file" : "Open a file"
        case .media:
            return mediaPath.isEmpty ? "Choose a \(mediaType) path" : mediaPath
        }
    }

    public var primaryResultField: String? {
        switch uiType {
        case .display: return nil
        case .choice: return "button_string"
        case .file: return "file_path"
        case .media: return "loops_ran"
        case .entry: return "value"
        case .confirm: return "confirmed"
        }
    }

    public func definition() throws -> StepDefinition {
        var result = StepDefinition(uiType: uiType)
        result.title = title.nilIfEmpty

        switch uiType {
        case .display:
            result.message = message
            result.button = displayButton.nilIfEmpty
            result.buttons = result.button.map { [$0] } ?? []
        case .choice:
            result.message = message
            result.buttons = buttons
        case .file:
            result.mode = fileMode
            result.directory = directory.nilIfEmpty
            result.filters = filters
            result.filename = fileMode == "save" ? filename.nilIfEmpty : nil
        case .media:
            result.mediaType = mediaType
            result.path = mediaPath
            if mediaType == "image" {
                guard autoClose.isFinite, autoClose >= 0 else {
                    throw StudioValidationError("Auto-close seconds must be zero or positive.")
                }
                result.autoClose = autoClose > 0 ? autoClose : nil
            } else {
                result.volume = volume
                result.forever = forever
                result.plays = forever ? nil : plays
            }
        case .entry:
            guard maxLength >= 0 else {
                throw StudioValidationError("Maximum length must be zero or positive.")
            }
            result.entryType = entryType
            result.message = message.nilIfEmpty
            result.defaultValue = defaultValue.nilIfEmpty
            result.required = required
            result.maxLength = maxLength > 0 ? maxLength : nil
            if entryType == "number" {
                result.min = minimum.nilIfEmpty
                result.max = maximum.nilIfEmpty
            }
        case .confirm:
            result.message = message
            result.confirmLabel = confirmLabel.nilIfEmpty
            result.cancelLabel = cancelLabel.nilIfEmpty
        }

        do {
            try DefinitionValidator.validate(&result)
        } catch let error as StructuredError {
            throw StudioValidationError(error.message)
        }
        return result
    }

    public func commandArguments() throws -> [String] {
        _ = try definition()
        var arguments = ["--ui-type", uiType.rawValue]
        append(&arguments, "--title", title.nilIfEmpty)

        switch uiType {
        case .display:
            append(&arguments, "--message", message)
            append(&arguments, "--button", displayButton.nilIfEmpty)
        case .choice:
            append(&arguments, "--message", message)
            buttons.forEach { append(&arguments, "--button", $0) }
        case .file:
            append(&arguments, "--mode", fileMode)
            append(&arguments, "--directory", directory.nilIfEmpty)
            filters.forEach { append(&arguments, "--filter", $0) }
            if fileMode == "save" { append(&arguments, "--filename", filename.nilIfEmpty) }
        case .media:
            append(&arguments, "--media-type", mediaType)
            append(&arguments, "--path", mediaPath)
            if mediaType == "image" {
                if autoClose > 0 { append(&arguments, "--auto-close", String(autoClose)) }
            } else {
                append(&arguments, "--volume", String(volume))
                if forever { arguments.append("--forever") }
                else { append(&arguments, "--plays", String(plays)) }
            }
        case .entry:
            append(&arguments, "--entry-type", entryType)
            append(&arguments, "--message", message.nilIfEmpty)
            append(&arguments, "--default", defaultValue.nilIfEmpty)
            if required { arguments.append("--required") }
            if maxLength > 0 { append(&arguments, "--max-length", String(maxLength)) }
            if entryType == "number" {
                append(&arguments, "--min", minimum.nilIfEmpty)
                append(&arguments, "--max", maximum.nilIfEmpty)
            }
        case .confirm:
            append(&arguments, "--message", message)
            append(&arguments, "--confirm-label", confirmLabel.nilIfEmpty)
            append(&arguments, "--cancel-label", cancelLabel.nilIfEmpty)
        }
        return arguments
    }

    private func append(_ arguments: inout [String], _ option: String, _ value: String?) {
        guard let value else { return }
        if value.hasPrefix("-") {
            arguments.append(option + "=" + value)
        } else {
            arguments.append(option)
            arguments.append(value)
        }
    }
}

public struct StudioValidationError: LocalizedError, Equatable, Sendable {
    public let message: String

    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

public extension UIType {
    var studioTitle: String {
        switch self {
        case .display: return "Display"
        case .choice: return "Choice"
        case .file: return "File"
        case .media: return "Media"
        case .entry: return "Entry"
        case .confirm: return "Confirm"
        }
    }

    var studioIcon: String {
        switch self {
        case .display: return "text.bubble"
        case .choice: return "list.bullet.circle"
        case .file: return "folder"
        case .media: return "play.rectangle"
        case .entry: return "character.cursor.ibeam"
        case .confirm: return "checkmark.shield"
        }
    }

    var studioDescription: String {
        switch self {
        case .display: return "Show a message"
        case .choice: return "Choose from buttons"
        case .file: return "Open or save a file"
        case .media: return "Present image, audio, or video"
        case .entry: return "Collect text or a number"
        case .confirm: return "Continue or stop the flow"
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
