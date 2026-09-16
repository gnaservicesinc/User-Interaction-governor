import Darwin
import Foundation
import Testing
@testable import GovernorCore

private final class TrackedRenderer: RendererHandle, @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false
    var wasStopped: Bool { lock.withLock { stopped } }
    func stop() { lock.withLock { stopped = true } }
}

private final class ControlledSupervisor: RendererSupervisor, @unchecked Sendable {
    struct Run {
        let request: RendererRequest
        let handle: TrackedRenderer
        let event: @Sendable (RendererEvent) -> Void
        let terminated: @Sendable (Int32) -> Void

        func send(_ kind: RendererEventKind, result: ResultDocument? = nil) {
            event(RendererEvent(kind: kind, uuid: request.uuid, runNumber: request.runNumber,
                                workerToken: request.workerToken, stepIndex: 0,
                                shownAt: TimeStamp.string(), stepResult: nil, result: result, error: nil))
        }

        func complete() {
            let step = StepResult(index: 0, uiType: .display, outcome: "accepted")
            send(.completed, result: ResultDocument(uuid: request.uuid, runNumber: request.runNumber,
                outcome: "completed", startedAt: TimeStamp.string(), finishedAt: TimeStamp.string(),
                length: 0, error: nil, steps: [step]))
        }
    }
    private let lock = NSLock()
    private var runs: [Run] = []
    var showOnLaunch = true
    func run(_ index: Int) -> Run { lock.withLock { runs[index] } }
    func launch(request: RendererRequest, event: @escaping @Sendable (RendererEvent) -> Void,
                terminated: @escaping @Sendable (Int32) -> Void) throws -> RendererHandle {
        let run = Run(request: request, handle: TrackedRenderer(), event: event, terminated: terminated)
        lock.withLock { runs.append(run) }
        if showOnLaunch { run.send(.shown) }
        return run.handle
    }
}

private final class EngineFixture {
    let paths: RuntimePaths
    let store: SQLiteStore
    let supervisor = ControlledSupervisor()
    let engine: GovernorEngine
    init() throws {
        // Keep below sockaddr_un's path length even with macOS's long temporary directory.
        paths = RuntimePaths(root: URL(fileURLWithPath: "/tmp/uig-regression-\(UUID().uuidString)"))
        try paths.prepare()
        store = try SQLiteStore(path: paths.database.path)
        engine = try GovernorEngine(store: store, paths: paths, supervisor: supervisor)
    }
    deinit { try? FileManager.default.removeItem(at: paths.root) }
    func request(_ action: GovernorAction, _ uuid: String? = nil,
                 options: [String: [String]] = [:]) -> IPCResponse {
        engine.handle(IPCRequest(action: action, uuid: uuid, options: options, flags: [], reset: [],
                                 workingDirectory: paths.root.path, sessionId: currentSessionID()))
    }
    func create() throws -> String {
        let response = request(.new, options: ["ui-type": ["display"], "message": ["Regression"]])
        return try governorJSONDecoder().decode(String.self, from: #require(response.payload))
    }
    func status(_ uuid: String) throws -> StatusDocument {
        try governorJSONDecoder().decode(StatusDocument.self, from: #require(request(.status, uuid).payload))
    }
}

@Test func oldRendererExitCannotDetachTheRearmedWorker() throws {
    let fixture = try EngineFixture()
    let uuid = try fixture.create()
    #expect(fixture.request(.trigger, uuid).ok)
    fixture.supervisor.run(0).complete()
    #expect(try fixture.status(uuid).state == 2)
    #expect(fixture.request(.rearm, uuid).ok)
    #expect(fixture.request(.trigger, uuid).ok)
    fixture.supervisor.run(0).terminated(0)
    #expect(try fixture.status(uuid).runNumber == 2)
    #expect(fixture.request(.end, uuid).ok)
    #expect(fixture.supervisor.run(1).handle.wasStopped)
}

@Test func timedOutRendererDoesNotSuppressANewerCrash() throws {
    let fixture = try EngineFixture()
    let uuid = try fixture.create()
    fixture.supervisor.showOnLaunch = false
    #expect(fixture.request(.trigger, uuid, options: ["start-timeout": ["0.01"]]).error?.code == "START_TIMEOUT")
    #expect(fixture.supervisor.run(0).handle.wasStopped)
    #expect(fixture.request(.rearm, uuid).ok)
    fixture.supervisor.showOnLaunch = true
    #expect(fixture.request(.trigger, uuid).ok)
    fixture.supervisor.run(1).terminated(9)
    #expect(try fixture.status(uuid).state == 2)
    #expect(try fixture.status(uuid).error?.code == "RENDERER_CRASH")
}

@Test func uppercaseUUIDAddressesTheSameInteraction() throws {
    let fixture = try EngineFixture()
    let uuid = try fixture.create()
    #expect(try fixture.status(uuid.uppercased()).state == 0)
    #expect(fixture.request(.end, uuid.uppercased()).ok)
    #expect(try fixture.status(uuid).state == 3)
}

@Test func deletedOwnedOutputCanBeRepublishedWithoutClobberingOtherFiles() throws {
    let fixture = try EngineFixture()
    let path = fixture.paths.root.appendingPathComponent("output").path
    let identity = try AtomicFiles.write(Data("first".utf8), to: path)
    try FileManager.default.removeItem(atPath: path)
    _ = try AtomicFiles.write(Data("second".utf8), to: path, allowReplacing: identity)
    #expect(try String(contentsOfFile: path, encoding: .utf8) == "second")
    let other = fixture.paths.root.appendingPathComponent("other").path
    let unrelated = try AtomicFiles.write(Data("unrelated".utf8), to: other)
    #expect(throws: StructuredError.self) {
        try AtomicFiles.write(Data("replace".utf8), to: path, allowReplacing: unrelated)
    }
    #expect(try String(contentsOfFile: path, encoding: .utf8) == "second")
}

@Test func serviceRecoveryFinishesPendingDelivery() throws {
    let fixture = try EngineFixture()
    let uuid = try fixture.create()
    #expect(fixture.request(.trigger, uuid).ok)
    fixture.supervisor.run(0).complete()
    #expect(try fixture.status(uuid).state == 2)
    let stored = try fixture.store.record(uuid: uuid)
    var record = try #require(stored)
    try FileManager.default.removeItem(atPath: record.paths.responsePath)
    try FileManager.default.removeItem(atPath: record.paths.userFinishedPath)
    record.deliveryError = ResultError(StructuredError("IO_ERROR", "completion delivery pending", retryable: true))
    try fixture.store.update(record)
    let recovered = try GovernorEngine(store: fixture.store, paths: fixture.paths, supervisor: fixture.supervisor)
    withExtendedLifetime(recovered) {
        #expect(FileManager.default.fileExists(atPath: record.paths.responsePath))
        #expect(FileManager.default.fileExists(atPath: record.paths.userFinishedPath))
    }
    #expect(try fixture.store.record(uuid: uuid)?.deliveryError == nil)
}

@Test func decimalBoundsDoNotRoundAwaySignificantDigits() throws {
    let lower = "1." + String(repeating: "0", count: 60) + "1"
    let upper = "1." + String(repeating: "0", count: 60) + "2"
    var step = StepDefinition(uiType: .entry)
    step.entryType = "number"
    step.max = lower
    #expect(throws: StructuredError.self) { try DefinitionValidator.validateEntry(upper, step: step) }
    step.max = nil
    step.min = upper
    #expect(throws: StructuredError.self) { try DefinitionValidator.validateEntry(lower, step: step) }
    #expect(try DefinitionValidator.compareDecimals("-" + lower, "-" + upper) == .orderedDescending)
    #expect(try DefinitionValidator.compareDecimals("+00.50", "0.5") == .orderedSame)
    step.min = nil
    try DefinitionValidator.validateEntry(String(repeating: "9", count: 200), step: step)
}

@Test func mediaAutoCloseRejectsNonfiniteAndNonpositiveValues() throws {
    for invalid in [Double.infinity, Double.nan, -1, 0] {
        var step = StepDefinition(uiType: .media)
        step.mediaType = "image"
        step.path = "/tmp/image.png"
        step.autoClose = invalid
        #expect(throws: StructuredError.self) { try DefinitionValidator.validate(&step) }
    }
}

@Test(.timeLimit(.minutes(1))) func processCaptureDrainsBothFullPipes() throws {
    let result = try ProcessCapture.run(URL(fileURLWithPath: "/bin/sh"), arguments: ["-c",
        "/bin/dd if=/dev/zero bs=1024 count=256 2>/dev/null; /bin/dd if=/dev/zero bs=1024 count=256 1>&2 2>/dev/null"])
    #expect(result.status == 0)
    #expect(result.output.count == 262144)
    #expect(result.error.count == 262144)
}

@Test func socketsAreNotInheritedByRenderers() throws {
    let fixture = try EngineFixture()
    let listener = try UnixSocket.listen(path: fixture.paths.socket.path)
    defer { close(listener) }
    let client = try UnixSocket.connect(path: fixture.paths.socket.path)
    defer { close(client) }
    #expect(fcntl(listener, F_GETFD) & FD_CLOEXEC != 0)
    #expect(fcntl(client, F_GETFD) & FD_CLOEXEC != 0)
}

@Test func fileFiltersValidateTypedNamesAsWellAsExistingFiles() {
    #expect(filenameMatchesFilters("report.TXT", filters: ["*.txt"]))
    #expect(!filenameMatchesFilters("report.pdf", filters: ["*.txt"]))
    #expect(filenameMatchesFilters("report-01.csv", filters: ["report-??.csv"]))
    #expect(filenameMatchesFilters("anything", filters: []))
}

@Test func lostIPCReplyIsReportedWithoutAttemptingToStartAnotherService() throws {
    let fixture = try EngineFixture()
    let listener = try UnixSocket.listen(path: fixture.paths.socket.path)
    defer { close(listener) }
    let received = DispatchSemaphore(value: 0)
    DispatchQueue.global().async {
        let connection = accept(listener, nil, nil)
        guard connection >= 0 else { return }
        _ = try? IPCWire.receive(IPCRequest.self, descriptor: connection)
        close(connection) // Simulate a commit followed by a lost reply.
        received.signal()
    }
    let client = IPCClient(paths: fixture.paths)
    do {
        _ = try client.send(IPCRequest(action: .new, uuid: nil, options: [:], flags: [], reset: [],
                                      workingDirectory: "/", sessionId: "test"))
        Issue.record("A lost reply must be reported to the caller")
    } catch let error as StructuredError {
        #expect(error.code == "IO_ERROR")
        #expect(error.message.contains("reading"))
    }
    #expect(received.wait(timeout: .now() + 2) == .success)
}

@Test func failureBetweenStepsMarksTheNextStepFailed() throws {
    let fixture = try EngineFixture()
    let uuid = try fixture.create()
    #expect(fixture.request(.stack, uuid, options: ["ui-type": ["display"], "message": ["Next"]]).ok)
    #expect(fixture.request(.trigger, uuid).ok)
    let run = fixture.supervisor.run(0)
    let step = StepResult(index: 0, uiType: .display, outcome: "accepted")
    run.event(RendererEvent(kind: .stepCompleted, uuid: uuid, runNumber: 1,
                           workerToken: run.request.workerToken, stepIndex: 0,
                           shownAt: nil, stepResult: step, result: nil, error: nil))
    run.terminated(1)
    #expect(try fixture.status(uuid).state == 2)
    let result = try governorJSONDecoder().decode(ResultDocument.self, from: #require(fixture.request(.dump, uuid).payload))
    #expect(result.steps.map(\.outcome) == ["accepted", "failed"])
}

@Test func unrepresentableExpirationIsRejectedWithoutCreatingState() throws {
    let fixture = try EngineFixture()
    let response = fixture.request(.new, options: ["ui-type": ["display"], "message": ["x"], "seconds": [String(Int.max)]])
    #expect(response.error?.code == "INVALID_ARGUMENT")
    #expect(try fixture.store.allRecords().isEmpty)
    let uuid = try fixture.create()
    let before = try fixture.status(uuid).expiresAt
    #expect(fixture.request(.extend, uuid, options: ["seconds": [String(Int.max)]]).error?.code == "INVALID_ARGUMENT")
    #expect(try fixture.status(uuid).expiresAt == before)
}

@Test func longDecimalNormalizationKeepsEverySignificantDigit() throws {
    let padding = String(repeating: "0", count: 100_000)
    #expect(try DefinitionValidator.normalizedDecimal("+" + padding + "1.25" + padding) == "1.25")
}
