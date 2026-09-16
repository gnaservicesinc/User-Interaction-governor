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
    #expect(script.hasPrefix("#!/usr/bin/env bash\n"))
    #expect(script.contains("GOVONER_BASH_RUNTIME='/usr/local/lib/ugl/govoner-runtime.sh'"))
    #expect(!script.contains("declare -A GOVONER_RAN_LAST"))
    #expect(script.contains("GOVONER_LAST_RUN_UUID=\"$uuid\""))
    #expect(script.contains("source \"$GOVONER_BASH_RUNTIME\""))
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

    let missingRuntime = FileManager.default.temporaryDirectory
        .appendingPathComponent("missing-govoner-runtime-\(UUID().uuidString).sh").path
    let guardURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("govoner-missing-runtime-\(UUID().uuidString).sh")
    defer { try? FileManager.default.removeItem(at: guardURL) }
    try Data(BashExporter.export(project, runtimePath: missingRuntime).utf8).write(to: guardURL)
    let guardProcess = Process()
    let guardError = Pipe()
    guardProcess.executableURL = URL(fileURLWithPath: "/bin/bash")
    guardProcess.arguments = [guardURL.path]
    guardProcess.standardError = guardError
    try guardProcess.run()
    guardProcess.waitUntilExit()
    let guardMessage = String(data: guardError.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    #expect(guardProcess.terminationStatus == 2)
    #expect(guardMessage.contains("Govoner Bash runtime not found"))
    #expect(script.contains(BashExporter.managedEndMarker))
}

@Test func managedExportReplacesOnlyItsHeaderAndPreservesTheScriptBody() throws {
    let first = StudioProject(name: "First", functionName: "first_ui", steps: [.template(for: .display)])
    let second = StudioProject(name: "Second", functionName: "second_ui", steps: [.template(for: .confirm)])
    let original = "#!/bin/bash\nset -e\necho keep-me\n"

    let initial = try BashExporter.updating(
        script: original,
        with: first,
        runtimePath: "/tmp/UGL/lib/ugl/govoner-runtime.sh"
    )
    #expect(initial.hasPrefix("#!/bin/bash\n"))
    #expect(initial.contains("first_ui()"))
    #expect(initial.hasSuffix("set -e\necho keep-me\n"))

    let updated = try BashExporter.updating(
        script: initial,
        with: second,
        runtimePath: "/Library/Frameworks/UGL.framework/Versions/Current/Resources/govoner-runtime.sh"
    )
    #expect(!updated.contains("first_ui()"))
    #expect(updated.contains("second_ui()"))
    #expect(updated.hasSuffix("set -e\necho keep-me\n"))
    #expect(updated.components(separatedBy: BashExporter.managedEndMarker).count == 2)
}

@Test func managedExportRejectsNonBashAndRelativeRuntimePaths() {
    let project = StudioProject.starter
    #expect(throws: StudioValidationError.self) {
        try BashExporter.updating(script: "#!/usr/bin/env python3\nprint('x')\n", with: project)
    }
    #expect(throws: StudioValidationError.self) {
        try BashExporter.export(project, runtimePath: "lib/ugl/govoner-runtime.sh")
    }
}

@Test func installLocationsExposeStableRuntimeAndPathEntries() {
    let prefix = UGLInstallLocation(layout: .prefix, selectedPath: "/opt/ugl")
    #expect(prefix.binDirectory.path == "/opt/ugl/bin")
    #expect(prefix.runtimeURL.path == "/opt/ugl/lib/ugl/govoner-runtime.sh")
    #expect(prefix.versionURL(for: uglComponents[0]).path == "/opt/ugl/lib/ugl/versions/uig.version")

    let framework = UGLInstallLocation(layout: .framework, selectedPath: "/Library/Frameworks/UGL.framework")
    #expect(framework.binDirectory.path == "/Library/Frameworks/UGL.framework/Versions/A/bin")
    #expect(framework.pathEntry == "/Library/Frameworks/UGL.framework/Versions/Current/bin")
    #expect(framework.runtimeURL.path == "/Library/Frameworks/UGL.framework/Versions/Current/Resources/govoner-runtime.sh")
    #expect(compareUGLVersion(installed: "0.9.0", bundled: "1.0.0") == .older)
    #expect(compareUGLVersion(installed: "1.0.0", bundled: "1.0.0") == .current)
    #expect(compareUGLVersion(installed: "2.0.0", bundled: "1.0.0") == .newer)
}

@Test func managementInstallPlanCopiesVersionsAndUninstallsKnownComponents() throws {
    let manager = FileManager.default
    let temporaryRoot = manager.temporaryDirectory.appendingPathComponent("ugl-plan-\(UUID().uuidString)", isDirectory: true)
    let bundled = temporaryRoot.appendingPathComponent("Bundled Components", isDirectory: true)
    try manager.createDirectory(at: bundled.appendingPathComponent("bin"), withIntermediateDirectories: true)
    try manager.createDirectory(at: bundled.appendingPathComponent("share"), withIntermediateDirectories: true)
    for component in uglComponents {
        let source = UGLInstallPlan.bundledURL(for: component, under: bundled)
        try Data("component \(component.id)\n".utf8).write(to: source)
    }
    let location = UGLInstallLocation(
        layout: .prefix,
        selectedPath: temporaryRoot.appendingPathComponent("UGL Install 'quoted'").path
    )
    defer { try? manager.removeItem(at: temporaryRoot) }

    try runShell(UGLInstallPlan.installScript(location: location, bundledRoot: bundled, version: "1.2.3"))
    for component in uglComponents {
        #expect(manager.fileExists(atPath: location.installedURL(for: component).path))
        let version = try String(contentsOf: location.versionURL(for: component), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(version == "1.2.3")
    }

    try runShell(UGLInstallPlan.uninstallScript(location: location))
    #expect(!manager.fileExists(atPath: location.root.path))

    let framework = UGLInstallLocation(
        layout: .framework,
        selectedPath: temporaryRoot.appendingPathComponent("UGL Test.framework").path
    )
    try runShell(UGLInstallPlan.installScript(location: framework, bundledRoot: bundled, version: "1.2.3"))
    let current = framework.root.appendingPathComponent("Versions/Current")
    #expect(try manager.destinationOfSymbolicLink(atPath: current.path) == "A")
    #expect(manager.fileExists(atPath: framework.runtimeURL.path))
    #expect(manager.fileExists(atPath: framework.pathEntry + "/uig"))
    try runShell(UGLInstallPlan.uninstallScript(location: framework))
    #expect(!manager.fileExists(atPath: framework.root.path))
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
    media.mediaWidth = 800
    media.mediaHeight = 450
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
    let mediaArguments = try media.commandArguments()
    let widthIndex = try #require(mediaArguments.firstIndex(of: "--width"))
    let heightIndex = try #require(mediaArguments.firstIndex(of: "--height"))
    #expect(mediaArguments[widthIndex + 1] == "800")
    #expect(mediaArguments[heightIndex + 1] == "450")

    media.mediaType = "audio"
    #expect(!((try media.commandArguments()).contains("--width")))
    #expect(!((try media.commandArguments()).contains("--height")))
}

@Test func projectsWithoutMediaDimensionsRemainDecodable() throws {
    let project = StudioProject.starter
    let data = try JSONEncoder().encode(project)
    var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    var steps = try #require(object["steps"] as? [[String: Any]])
    steps[0].removeValue(forKey: "mediaWidth")
    steps[0].removeValue(forKey: "mediaHeight")
    object["steps"] = steps
    let legacy = try JSONSerialization.data(withJSONObject: object)
    let decoded = try JSONDecoder().decode(StudioProject.self, from: legacy)
    #expect(decoded.steps[0].mediaWidth == nil)
    #expect(decoded.steps[0].mediaHeight == nil)
}

private func runShell(_ script: String) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/bash")
    process.arguments = ["-c", script]
    try process.run()
    process.waitUntilExit()
    #expect(process.terminationStatus == 0)
}

@Test func exportedArgumentsPreserveNegativeAndOptionLikeValues() throws {
    var entry = StudioStep.template(for: .entry)
    entry.entryType = "number"
    entry.defaultValue = "-2.5"
    entry.minimum = "-10"
    entry.message = "--literal message"
    let parsed = try ArgumentParser.parse(["--new"] + entry.commandArguments())
    let definition = try DefinitionValidator.step(options: parsed.options, flags: parsed.flags, workingDirectory: "/")
    #expect(definition.defaultValue == "-2.5")
    #expect(definition.min == "-10")
    #expect(definition.message == "--literal message")
}

@Test func exportedFunctionCannotShadowRuntimeOrShellSyntax() {
    for name in ["if", "time", "govoner_poll", "govoner_wait", "govoner_end", "local", "command"] {
        #expect(throws: StudioValidationError.self) {
            try BashExporter.export(StudioProject(functionName: name))
        }
    }
}

@Test func exportPropagatesRuntimeVersionFailure() throws {
    let runtime = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Components/govoner-runtime.sh")
    let script = try BashExporter.export(.starter, runtimePath: runtime.path) + "\necho should-not-run\n"
    let result = try ProcessCapture.run(URL(fileURLWithPath: "/bin/bash"), arguments: ["-c", script])
    #expect(result.status == 2)
    #expect(result.output.isEmpty)
    #expect(String(decoding: result.error, as: UTF8.self).contains("Bash 4 or newer"))
}

@Test func managedUpdatePreservesMarkerTextAndIsIdempotent() throws {
    let project = StudioProject.starter
    let original = "#!/bin/bash\nprintf '%s\\n' '\(BashExporter.managedEndMarker)'\necho keep\n"
    let once = try BashExporter.updating(script: original, with: project)
    #expect(once.hasSuffix(String(original.dropFirst("#!/bin/bash\n".count))))
    #expect(try BashExporter.updating(script: once, with: project) == once)
    let withoutFinalNewline = try BashExporter.export(project).trimmingCharacters(in: .newlines)
    let updated = try BashExporter.updating(script: withoutFinalNewline, with: StudioProject(functionName: "replacement"))
    #expect(!updated.contains("run_govoner_interaction()"))
    #expect(updated.contains("replacement()"))
    var step = StudioStep.template(for: .display)
    step.message = "start\n\(BashExporter.managedEndMarker)\nend"
    let embedded = try BashExporter.export(StudioProject(steps: [step])) + "echo keep\n"
    let replaced = try BashExporter.updating(script: embedded, with: project)
    #expect(replaced.hasSuffix("echo keep\n"))
    #expect(!replaced.contains("end'"))
    let quoted = BashExporter.shellQuote(step.message)
    let roundTrip = try ProcessCapture.run(URL(fileURLWithPath: "/bin/bash"), arguments: ["-c", "printf %s " + quoted])
    #expect(String(decoding: roundTrip.output, as: UTF8.self) == step.message)
}

@Test func installAndUninstallRejectInvalidLocations() throws {
    let bundled = URL(fileURLWithPath: "/unused")
    for path in ["", "relative", "/", "/Users/..", "/tmp/bad\npath"] {
        let location = UGLInstallLocation(layout: .prefix, selectedPath: path)
        #expect(throws: UGLInstallationPlanError.self) {
            try UGLInstallPlan.installScript(location: location, bundledRoot: bundled)
        }
        #expect(throws: UGLInstallationPlanError.self) {
            try UGLInstallPlan.uninstallScript(location: location)
        }
    }
}

@Test func managedUpdatesHandleCRLFAndRejectMisleadingShebangs() throws {
    let original = "#!/usr/bin/env bash\r\necho keep\r\n"
    let updated = try BashExporter.updating(script: original, with: .starter)
    #expect(updated.hasSuffix("echo keep\r\n"))
    #expect(try BashExporter.updating(script: updated, with: .starter) == updated)
    for shebang in ["#!/usr/bin/env python3 # bash", "#!/bin/notbash"] {
        #expect(throws: StudioValidationError.self) {
            try BashExporter.updating(script: shebang + "\necho keep\n", with: .starter)
        }
    }
}

@Test func studioDoesNotSilentlyDiscardInvalidNumericSettings() throws {
    var media = StudioStep.template(for: .media)
    media.mediaPath = "/tmp/image.png"
    for invalid in [-1, Double.infinity, Double.nan] {
        media.autoClose = invalid
        #expect(throws: StudioValidationError.self) { try media.definition() }
    }
    var entry = StudioStep.template(for: .entry)
    entry.maxLength = -1
    #expect(throws: StudioValidationError.self) { try entry.commandArguments() }
}
