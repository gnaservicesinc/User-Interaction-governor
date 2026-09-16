import Foundation
import GovernorCore
import Testing
@testable import GovonerStudioCore

@Test func bashExportIncludesSharedConcurrentResultContract() throws {
    var display = StudioStep.template(for: .display)
    display.message = "It's ready\nfor everyone"
    var choice = StudioStep.template(for: .choice)
    choice.message = "$uuid"
    choice.buttons = ["Ship", "Wait"]
    let project = StudioProject(
        name: "Release gate",
        functionName: "run_release_gate",
        steps: [display, choice]
    )

    let script = try BashExporter.export(project)
    #expect(script.contains("declare -A GOVONER_RAN_LAST"))
    #expect(script.contains("GOVONER_LAST_RUN_UUID=\"$uuid\""))
    #expect(script.contains("govoner_poll()"))
    #expect(script.contains("govoner_wait()"))
    #expect(script.contains("run_release_gate()"))
    #expect(script.contains("GOVONER_RAN_STEP_FIELD[\"$uuid:1\"]='button_string'"))
    #expect(script.contains("'It'\"'\"'s ready\nfor everyone'"))
    #expect(script.contains("command uig --stack"))
    #expect(script.contains("\n      '$uuid'"))

    let url = FileManager.default.temporaryDirectory.appendingPathComponent("govoner-export-\(UUID().uuidString).sh")
    defer { try? FileManager.default.removeItem(at: url) }
    try Data(script.utf8).write(to: url)
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/bash")
    process.arguments = ["-n", url.path]
    try process.run()
    process.waitUntilExit()
    #expect(process.terminationStatus == 0)

    let guardProcess = Process()
    let guardError = Pipe()
    guardProcess.executableURL = URL(fileURLWithPath: "/bin/bash")
    guardProcess.arguments = [url.path]
    guardProcess.standardError = guardError
    try guardProcess.run()
    guardProcess.waitUntilExit()
    let guardMessage = String(data: guardError.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    #expect(guardProcess.terminationStatus == 2)
    #expect(guardMessage.contains("require Bash 4 or newer"))
}

@Test func projectRoundTripsAndProducesGovernorDefinitions() throws {
    var entry = StudioStep.template(for: .entry)
    entry.entryType = "number"
    entry.minimum = "-1.5"
    entry.maximum = "20"
    entry.defaultValue = "2.5"
    entry.required = true
    let project = StudioProject(name: "Numbers", functionName: "ask_number", steps: [entry])

    let data = try JSONEncoder().encode(project)
    let decoded = try JSONDecoder().decode(StudioProject.self, from: data)
    #expect(decoded == project)
    let definitions = try decoded.validatedDefinitions()
    #expect(definitions.count == 1)
    #expect(definitions[0].entryType == "number")
    #expect(definitions[0].min == "-1.5")
}

@Test func invalidFunctionAndInvalidInteractionAreRejected() {
    let invalidName = StudioProject(functionName: "not-a-function")
    #expect(throws: StudioValidationError.self) { try BashExporter.export(invalidName) }
    #expect(throws: StudioValidationError.self) {
        try BashExporter.export(StudioProject(functionName: "rún_ui"))
    }

    var choice = StudioStep.template(for: .choice)
    choice.buttons = ["Only one"]
    let invalidChoice = StudioProject(functionName: "ask", steps: [choice])
    #expect(throws: StudioValidationError.self) { try BashExporter.export(invalidChoice) }
}

@Test func everyConfiguredInteractionTypeBuildsArguments() throws {
    var file = StudioStep.template(for: .file)
    file.directory = FileManager.default.temporaryDirectory.path
    var media = StudioStep.template(for: .media)
    media.mediaPath = "/tmp/preview.png"
    let steps = [
        StudioStep.template(for: .display),
        StudioStep.template(for: .choice),
        file,
        media,
        StudioStep.template(for: .entry),
        StudioStep.template(for: .confirm),
    ]
    for step in steps {
        let arguments = try step.commandArguments()
        #expect(arguments.prefix(2) == ["--ui-type", step.uiType.rawValue])
    }
}
