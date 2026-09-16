import Darwin
import Foundation
import Testing
@testable import GovernorCore

@Test func argumentAliasesAndEqualsValues() throws {
    let parsed = try ArgumentParser.parse(["--new", "--ui_type=DISPLAY", "--message=--literal", "--window_width=640"])
    #expect(parsed.action == .new)
    #expect(parsed.value("ui-type") == "DISPLAY")
    #expect(parsed.value("message") == "--literal")
    #expect(parsed.value("width") == "640")
}

@Test func decimalNormalizationIsExact() throws {
    #expect(try DefinitionValidator.normalizedDecimal(" +001.5000 ") == "1.5")
    #expect(try DefinitionValidator.normalizedDecimal("-0") == "0")
    #expect(throws: StructuredError.self) { try DefinitionValidator.normalizedDecimal("1e3") }
    #expect(throws: StructuredError.self) { try DefinitionValidator.normalizedDecimal("NaN") }
}

@Test func choiceAndMediaValidation() throws {
    let choice = try DefinitionValidator.step(options: ["ui-type": ["choice"], "message": ["Continue?"]], flags: [], workingDirectory: "/")
    #expect(choice.buttons == ["Yes", "No"])
    #expect(throws: StructuredError.self) {
        try DefinitionValidator.step(options: ["ui-type": ["media"], "media-type": ["image"], "path": ["/tmp/x"], "plays": ["2"]], flags: [], workingDirectory: "/")
    }
    let image = try DefinitionValidator.step(
        options: ["ui-type": ["media"], "media-type": ["image"], "path": ["/tmp/x"],
                  "width": ["640"], "height": ["360"]], flags: [], workingDirectory: "/"
    )
    #expect(image.width == 640)
    #expect(image.height == 360)
    #expect(throws: StructuredError.self) {
        try DefinitionValidator.step(
            options: ["ui-type": ["media"], "media-type": ["audio"], "path": ["/tmp/x"], "width": ["640"]],
            flags: [], workingDirectory: "/"
        )
    }
    #expect(throws: StructuredError.self) {
        try DefinitionValidator.step(
            options: ["ui-type": ["media"], "media-type": ["video"], "path": ["/tmp/x"], "height": ["0"]],
            flags: [], workingDirectory: "/"
        )
    }
    #expect(throws: StructuredError.self) {
        try DefinitionValidator.step(
            options: ["ui-type": ["display"], "message": ["Hello"], "width": ["640"]],
            flags: [], workingDirectory: "/"
        )
    }
}

private final class FakeHandle: RendererHandle, @unchecked Sendable { func stop() {} }

private final class FakeSupervisor: RendererSupervisor, @unchecked Sendable {
    func launch(request: RendererRequest, event: @escaping @Sendable (RendererEvent) -> Void, terminated: @escaping @Sendable (Int32) -> Void) throws -> RendererHandle {
        DispatchQueue.global().async {
            let shown = TimeStamp.string()
            event(RendererEvent(kind: .shown, uuid: request.uuid, runNumber: request.runNumber, workerToken: request.workerToken, stepIndex: 0, shownAt: shown, stepResult: nil, result: nil, error: nil))
            var step = StepResult(index: 0, uiType: request.steps[0].uiType, outcome: "accepted")
            step.closeReason = "button"
            step.status = 1
            step.shownAt = shown
            step.finishedAt = TimeStamp.string()
            step.length = 0
            event(RendererEvent(kind: .stepCompleted, uuid: request.uuid, runNumber: request.runNumber, workerToken: request.workerToken, stepIndex: 0, shownAt: nil, stepResult: step, result: nil, error: nil))
            let result = ResultDocument(uuid: request.uuid, runNumber: request.runNumber, outcome: "completed", startedAt: shown, finishedAt: TimeStamp.string(), length: 0, error: nil, steps: [step])
            event(RendererEvent(kind: .completed, uuid: request.uuid, runNumber: request.runNumber, workerToken: request.workerToken, stepIndex: nil, shownAt: nil, stepResult: nil, result: result, error: nil))
        }
        return FakeHandle()
    }
}

private func temporaryRuntime() throws -> RuntimePaths {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("uig-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    _ = chmod(url.path, 0o700)
    let paths = RuntimePaths(root: url)
    try paths.prepare()
    return paths
}

@Test func lifecyclePersistsAndPublishesInOrder() throws {
    let paths = try temporaryRuntime()
    defer { try? FileManager.default.removeItem(at: paths.root) }
    let store = try SQLiteStore(path: paths.database.path)
    let engine = try GovernorEngine(store: store, paths: paths, supervisor: FakeSupervisor())
    let create = IPCRequest(action: .new, uuid: nil, options: ["ui-type": ["display"], "message": ["Test"]], flags: [], reset: [], workingDirectory: paths.root.path, sessionId: currentSessionID())
    let createResponse = engine.handle(create)
    #expect(createResponse.ok)
    let uuid = try governorJSONDecoder().decode(String.self, from: createResponse.payload!)
    let trigger = IPCRequest(action: .trigger, uuid: uuid, options: [:], flags: [], reset: [], workingDirectory: paths.root.path, sessionId: currentSessionID())
    #expect(engine.handle(trigger).ok)
    for _ in 0..<100 {
        if try store.record(uuid: uuid)?.state == .postRun { break }
        usleep(10_000)
    }
    let stored = try store.record(uuid: uuid)
    let record = try #require(stored)
    #expect(record.state == .postRun)
    #expect(record.result?.outcome == "completed")
    #expect(FileManager.default.fileExists(atPath: record.paths.responsePath))
    #expect(FileManager.default.fileExists(atPath: record.paths.userFinishedPath))
    let responseData = try Data(contentsOf: URL(fileURLWithPath: record.paths.responsePath))
    #expect((try governorJSONDecoder().decode(ResultDocument.self, from: responseData)).runNumber == 1)
}

@Test func reservedProtocolPathCannotBeReused() throws {
    let paths = try temporaryRuntime()
    defer { try? FileManager.default.removeItem(at: paths.root) }
    let store = try SQLiteStore(path: paths.database.path)
    let now = Date()
    let shared = paths.root.appendingPathComponent("shared").path
    func record(_ uuid: String) -> InteractionRecord {
        let dir = paths.directory(for: uuid)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return InteractionRecord(schemaVersion: 1, uuid: uuid, ownerUid: getuid(), sessionId: "test", createdAt: TimeStamp.string(now), initialLifetimeSeconds: 60, expiresAt: TimeStamp.string(now.addingTimeInterval(60)), definitionRevision: 1, runNumber: 0, state: .setup, phase: "idle", stackLocked: false, definition: InteractionDefinition(steps: [StepDefinition(uiType: .display)]), paths: ProtocolPaths(triggerPath: shared, shownPath: dir.appendingPathComponent("s").path, userFinishedPath: dir.appendingPathComponent("f").path, responsePath: dir.appendingPathComponent("r").path, exitPath: dir.appendingPathComponent("e").path, uuidPath: dir.appendingPathComponent("u").path), explicitlyRequestedUuidPath: false, result: nil, deliveryError: nil, workerToken: nil, acceptedAt: nil, currentStepIndex: nil, currentStepShownAt: nil, partialResults: [])
    }
    let first = UUID().uuidString.lowercased()
    let second = UUID().uuidString.lowercased()
    try store.insert(record(first))
    #expect(throws: StructuredError.self) { try store.insert(record(second)) }
}

@Test func resultJSONPreservesNullAndTypeSpecificFields() throws {
    var step = StepResult(index: 0, uiType: .choice, outcome: "dismissed")
    step.closeReason = "window_close"
    step.status = -1
    step.buttonNumber = -1
    let result = ResultDocument(uuid: UUID().uuidString.lowercased(), runNumber: 1, outcome: "dismissed", startedAt: nil, finishedAt: TimeStamp.string(), length: nil, error: nil, steps: [step])
    let data = try governorJSONEncoder().encode(result)
    let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(object["started_at"] is NSNull)
    #expect(object["length"] is NSNull)
    #expect(object["error"] is NSNull)
    let steps = try #require(object["steps"] as? [[String: Any]])
    #expect(steps[0]["shown_at"] is NSNull)
    #expect(steps[0]["button_string"] is NSNull)
    #expect(steps[0]["error"] is NSNull)
}

private final class SlowSupervisor: RendererSupervisor, @unchecked Sendable {
    let launched = DispatchSemaphore(value: 0)

    func launch(request: RendererRequest, event: @escaping @Sendable (RendererEvent) -> Void, terminated: @escaping @Sendable (Int32) -> Void) throws -> RendererHandle {
        launched.signal()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.15) {
            event(RendererEvent(kind: .shown, uuid: request.uuid, runNumber: request.runNumber, workerToken: request.workerToken, stepIndex: 0, shownAt: TimeStamp.string(), stepResult: nil, result: nil, error: nil))
        }
        return FakeHandle()
    }
}

private final class ResponseBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: IPCResponse?
    func set(_ value: IPCResponse) { lock.withLock { self.value = value } }
    func get() -> IPCResponse? { lock.withLock { value } }
}

@Test func duplicateConcurrentTriggerCreatesOneRun() throws {
    let paths = try temporaryRuntime()
    defer { try? FileManager.default.removeItem(at: paths.root) }
    let store = try SQLiteStore(path: paths.database.path)
    let supervisor = SlowSupervisor()
    let engine = try GovernorEngine(store: store, paths: paths, supervisor: supervisor)
    let create = IPCRequest(action: .new, uuid: nil, options: ["ui-type": ["display"], "message": ["Race"]], flags: [], reset: [], workingDirectory: paths.root.path, sessionId: currentSessionID())
    let uuid = try governorJSONDecoder().decode(String.self, from: engine.handle(create).payload!)
    let trigger = IPCRequest(action: .trigger, uuid: uuid, options: ["start-timeout": ["2"]], flags: [], reset: [], workingDirectory: paths.root.path, sessionId: currentSessionID())
    let first = ResponseBox()
    let finished = DispatchSemaphore(value: 0)
    DispatchQueue.global().async { first.set(engine.handle(trigger)); finished.signal() }
    #expect(supervisor.launched.wait(timeout: .now() + 1) == .success)
    let duplicate = engine.handle(trigger)
    #expect(!duplicate.ok)
    #expect(duplicate.error?.code == "BUSY")
    #expect(finished.wait(timeout: .now() + 2) == .success)
    #expect(first.get()?.ok == true)
    let runningRecord = try store.record(uuid: uuid)
    #expect(runningRecord?.runNumber == 1)
    let end = IPCRequest(action: .end, uuid: uuid, options: [:], flags: [], reset: [], workingDirectory: paths.root.path, sessionId: currentSessionID())
    #expect(engine.handle(end).ok)
    #expect(engine.handle(end).ok)
}

@Test func expiredInteractionCannotBeExtended() throws {
    let paths = try temporaryRuntime()
    defer { try? FileManager.default.removeItem(at: paths.root) }
    let store = try SQLiteStore(path: paths.database.path)
    let engine = try GovernorEngine(store: store, paths: paths, supervisor: FakeSupervisor())
    let create = IPCRequest(action: .new, uuid: nil, options: ["ui-type": ["display"], "message": ["Expiry"], "seconds": ["1"]], flags: [], reset: [], workingDirectory: paths.root.path, sessionId: currentSessionID())
    let uuid = try governorJSONDecoder().decode(String.self, from: engine.handle(create).payload!)
    let stored = try store.record(uuid: uuid)
    var record = try #require(stored)
    record.expiresAt = TimeStamp.string(Date().addingTimeInterval(-1))
    try store.update(record)
    let extend = IPCRequest(action: .extend, uuid: uuid, options: [:], flags: [], reset: [], workingDirectory: paths.root.path, sessionId: currentSessionID())
    let response = engine.handle(extend)
    #expect(!response.ok)
    #expect(response.error?.code == "NOT_FOUND")
    let status = IPCRequest(action: .status, uuid: uuid, options: [:], flags: [], reset: [], workingDirectory: paths.root.path, sessionId: currentSessionID())
    let document = try governorJSONDecoder().decode(StatusDocument.self, from: engine.handle(status).payload!)
    #expect(document.state == 3)
}
