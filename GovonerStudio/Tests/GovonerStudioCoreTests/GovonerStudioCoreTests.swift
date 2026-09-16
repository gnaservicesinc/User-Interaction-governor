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

    let guardProcess = Process()
    let guardError = Pipe()
    guardProcess.executableURL = URL(fileURLWithPath: "/bin/bash")
    guardProcess.arguments = [url.path]
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

private func runShell(_ script: String) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/bash")
    process.arguments = ["-c", script]
    try process.run()
    process.waitUntilExit()
    #expect(process.terminationStatus == 0)
}
