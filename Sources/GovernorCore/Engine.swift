import Darwin
import Foundation

public protocol RendererHandle: AnyObject, Sendable {
    func stop()
}

public protocol RendererSupervisor: AnyObject, Sendable {
    func launch(
        request: RendererRequest,
        event: @escaping @Sendable (RendererEvent) -> Void,
        terminated: @escaping @Sendable (Int32) -> Void
    ) throws -> RendererHandle
}

private final class StartWaiter: @unchecked Sendable {
    let semaphore = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var completed = false
    private var storedError: StructuredError?

    func finish(_ error: StructuredError? = nil) {
        lock.lock()
        guard !completed else { lock.unlock(); return }
        completed = true
        storedError = error
        lock.unlock()
        semaphore.signal()
    }

    var error: StructuredError? { lock.withLock { storedError } }
}

public final class GovernorEngine: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.gnaservices.uig.engine")
    private let store: SQLiteStore
    private let paths: RuntimePaths
    private let supervisor: RendererSupervisor
    private var workers: [String: RendererHandle] = [:]
    private var waiters: [String: StartWaiter] = [:]
    private let maximumRenderers = 32

    public init(store: SQLiteStore, paths: RuntimePaths, supervisor: RendererSupervisor) throws {
        self.store = store
        self.paths = paths
        self.supervisor = supervisor
        try queue.sync { try recoverLocked() }
    }

    public func handle(_ request: IPCRequest) -> IPCResponse {
        var request = request
        request.uuid = request.uuid?.lowercased()
        do {
            if request.action == .trigger {
                return try trigger(request)
            }
            return try queue.sync { try handleLocked(request) }
        } catch let error as StructuredError {
            return .failure(error)
        } catch {
            return .failure(StructuredError("IO_ERROR", error.localizedDescription))
        }
    }

    public func scanSignalsAndExpiry() {
        queue.async {
            do {
                for record in try self.store.allRecords() {
                    do {
                        if self.isExpired(record) {
                            try self.endLocked(record, expiry: true)
                            continue
                        }
                        let exitExists = safeProtocolSignalExists(record.paths.exitPath)
                        let triggerExists = safeProtocolSignalExists(record.paths.triggerPath)
                        if exitExists {
                            _ = unlink(record.paths.exitPath)
                            try self.endLocked(record, expiry: false)
                        } else if triggerExists {
                            _ = unlink(record.paths.triggerPath)
                            if record.state == .setup {
                                let request = IPCRequest(action: .trigger, uuid: record.uuid, options: [:], flags: [], reset: [], workingDirectory: "/", sessionId: record.sessionId)
                                DispatchQueue.global(qos: .userInitiated).async { _ = self.handle(request) }
                            }
                        } else if record.state == .postRun, record.deliveryError != nil {
                            try? self.publishCompletionLocked(uuid: record.uuid)
                        }
                    } catch { continue }
                }
                try self.retryTombstonesLocked()
            } catch {
                // The next timer tick retries. No user data is logged.
            }
        }
    }

    private func handleLocked(_ request: IPCRequest) throws -> IPCResponse {
        switch request.action {
        case .new: return try createLocked(request)
        case .update: return try updateLocked(request)
        case .stack: return try stackLocked(request)
        case .status: return try statusLocked(request)
        case .dump:
            let record = try finalRecordLocked(request)
            return IPCResponse(ok: true, payload: try governorJSONEncoder(pretty: true).encode(record.result!), error: nil)
        case .get:
            let record = try finalRecordLocked(request)
            return try IPCResponse.success(record.result!)
        case .rearm: return try rearmLocked(request)
        case .extend: return try extendLocked(request)
        case .end: return try endRequestLocked(request)
        case .trigger: throw StructuredError("INVALID_STATE", "trigger dispatch reached an invalid internal state")
        }
    }

    private func createLocked(_ request: IPCRequest) throws -> IPCResponse {
        guard request.uuid == nil else { throw StructuredError("INVALID_ARGUMENT", "--new does not accept --uuid") }
        var step = try DefinitionValidator.step(options: request.options, flags: Set(request.flags), workingDirectory: request.workingDirectory)
        try DefinitionValidator.validate(&step)
        let definition = InteractionDefinition(steps: [step])
        try DefinitionValidator.validate(definition)
        let lifetime = try DefinitionValidator.lifetime(options: request.options)
        if let format = request.options["response-format"]?.last, format.lowercased() != "json" {
            throw StructuredError("INVALID_ARGUMENT", "JSON is the only response format in version 1")
        }

        let uuid = UUID().uuidString.lowercased()
        let directory = paths.directory(for: uuid)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        guard chmod(directory.path, 0o700) == 0 else {
            try? FileManager.default.removeItem(at: directory)
            throw StructuredError("IO_ERROR", "cannot secure interaction directory")
        }

        do {
            func protocolPath(_ option: String, _ defaultName: String) throws -> String {
                if let supplied = request.options[option]?.last {
                    let resolved = absolutePath(supplied, relativeTo: request.workingDirectory)
                    try validatePrivateParent(of: resolved)
                    let privateRoot = pathReservationKey(self.paths.root.standardizedFileURL.path + "/")
                    guard !pathReservationKey(resolved).hasPrefix(privateRoot) else { throw StructuredError("PATH_CONFLICT", "custom protocol paths cannot alias private governor state") }
                    return resolved
                }
                return directory.appendingPathComponent(defaultName).path
            }
            let protocolPaths = try ProtocolPaths(
                triggerPath: protocolPath("trigger-path", "trigger"),
                shownPath: protocolPath("shown-path", "shown.json"),
                userFinishedPath: protocolPath("user-finished-path", "finished.json"),
                responsePath: protocolPath("response-path", "response.json"),
                exitPath: protocolPath("exit-path", "exit"),
                uuidPath: protocolPath("uuid-path", "uuid")
            )
            let unique = Set(protocolPaths.all.map { pathReservationKey($0.path) })
            guard unique.count == protocolPaths.all.count else { throw StructuredError("PATH_CONFLICT", "all protocol paths must be distinct") }
            for item in protocolPaths.all where FileManager.default.fileExists(atPath: item.path) || AtomicFiles.identity(at: item.path) != nil {
                throw StructuredError("PATH_CONFLICT", "protocol path already exists: \(item.path)")
            }
            let now = Date()
            let record = InteractionRecord(
                schemaVersion: schemaVersion, uuid: uuid, ownerUid: getuid(), sessionId: request.sessionId,
                createdAt: TimeStamp.string(now), initialLifetimeSeconds: lifetime,
                expiresAt: try expirationString(now.addingTimeInterval(TimeInterval(lifetime))), definitionRevision: 1,
                runNumber: 0, state: .setup, phase: "idle", stackLocked: false,
                definition: definition, paths: protocolPaths,
                explicitlyRequestedUuidPath: request.options["uuid-path"] != nil,
                result: nil, deliveryError: nil, workerToken: nil, acceptedAt: nil,
                currentStepIndex: nil, currentStepShownAt: nil, partialResults: []
            )
            try store.insert(record)
            if record.explicitlyRequestedUuidPath {
                var createdIdentity: FileIdentity?
                do {
                    let identity = try AtomicFiles.write(Data((uuid + "\n").utf8), to: record.paths.uuidPath)
                    createdIdentity = identity
                    try store.setIdentity(uuid: uuid, role: "uuid_path", path: record.paths.uuidPath, identity: identity)
                } catch {
                    try? AtomicFiles.removeIfOwned(record.paths.uuidPath, identity: createdIdentity)
                    try? store.deleteNew(uuid: uuid)
                    throw error
                }
            }
            return try IPCResponse.success(uuid)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    private func updateLocked(_ request: IPCRequest) throws -> IPCResponse {
        var record = try mutableSetupRecord(request)
        guard !record.stackLocked else { throw StructuredError("INVALID_STATE", "an interaction cannot be updated after stacking") }
        let forbidden = ["ui-type", "trigger-path", "shown-path", "user-finished-path", "response-path", "response-format", "exit-path", "uuid-path", "days", "hours", "seconds"]
        if let option = forbidden.first(where: { request.options[$0] != nil }) {
            throw StructuredError("INVALID_ARGUMENT", "--\(option) cannot be changed with --update")
        }
        let supplied = Set(request.options.keys).union(request.flags)
        if let conflict = request.reset.first(where: { supplied.contains($0) }) {
            throw StructuredError("INVALID_ARGUMENT", "cannot set and reset --\(conflict) together")
        }
        var step = record.definition.steps[0]
        try applyUpdate(options: request.options, flags: Set(request.flags), resets: request.reset, workingDirectory: request.workingDirectory, step: &step)
        try DefinitionValidator.validate(&step)
        record.definition.steps[0] = step
        try DefinitionValidator.validate(record.definition)
        record.definitionRevision += 1
        try store.update(record)
        return .empty
    }

    private func stackLocked(_ request: IPCRequest) throws -> IPCResponse {
        var record = try mutableSetupRecord(request)
        guard record.definition.steps.count < DefinitionValidator.maximumSteps else { throw StructuredError("INVALID_ARGUMENT", "interaction already has the maximum number of steps") }
        let forbidden = ["trigger-path", "shown-path", "user-finished-path", "response-path", "response-format", "exit-path", "uuid-path", "days", "hours", "seconds"]
        if let option = forbidden.first(where: { request.options[$0] != nil }) { throw StructuredError("INVALID_ARGUMENT", "--\(option) is session-level and invalid with --stack") }
        let step = try DefinitionValidator.step(options: request.options, flags: Set(request.flags), workingDirectory: request.workingDirectory)
        record.definition.steps.append(step)
        try DefinitionValidator.validate(record.definition)
        record.stackLocked = true
        record.definitionRevision += 1
        try store.update(record)
        return .empty
    }

    private func trigger(_ request: IPCRequest) throws -> IPCResponse {
        let timeout = try parsePositiveTimeout(request.options["start-timeout"]?.last, defaultValue: 10)
        let waiter: StartWaiter = try queue.sync { try beginTriggerLocked(request) }
        if waiter.semaphore.wait(timeout: .now() + timeout) == .timedOut {
            let didAbort = queue.sync { self.timeoutTriggerLocked(uuid: request.uuid!, waiter: waiter) }
            if didAbort { throw StructuredError("START_TIMEOUT", "renderer did not present its first window before the startup deadline", retryable: true) }
        }
        if let error = waiter.error { throw error }
        return .empty
    }

    private func beginTriggerLocked(_ request: IPCRequest) throws -> StartWaiter {
        guard let uuid = request.uuid else { throw StructuredError("INVALID_ARGUMENT", "--trigger requires --uuid") }
        var record = try existingRecordLocked(uuid)
        try expireIfNeededLocked(record)
        record = try existingRecordLocked(uuid)
        guard record.state == .setup else { throw StructuredError(record.state == .live ? "BUSY" : "INVALID_STATE", "interaction is not in setup", retryable: record.state == .live) }
        guard record.sessionId == request.sessionId else { throw StructuredError("NO_DISPLAY", "interaction belongs to a different desktop session") }
        guard workers.count < maximumRenderers else { throw StructuredError("BUSY", "renderer limit reached", retryable: true) }
        try DefinitionValidator.validate(record.definition)
        try preflight(record.definition)
        record.runNumber += 1
        record.state = .live
        record.phase = "starting"
        record.workerToken = UUID().uuidString.lowercased()
        record.acceptedAt = TimeStamp.string()
        record.currentStepIndex = 0
        record.currentStepShownAt = nil
        record.partialResults = []
        record.result = nil
        record.deliveryError = nil
        try store.update(record)
        let waiter = StartWaiter()
        waiters[uuid] = waiter
        let rendererRequest = RendererRequest(uuid: uuid, runNumber: record.runNumber, workerToken: record.workerToken!, steps: record.definition.steps)
        do {
            let handle = try supervisor.launch(request: rendererRequest, event: { [weak self] event in
                self?.queue.async { self?.receiveLocked(event) }
            }, terminated: { [weak self] status in
                self?.queue.async { self?.rendererTerminatedLocked(uuid: uuid, runNumber: record.runNumber, token: record.workerToken!, status: status) }
            })
            workers[uuid] = handle
        } catch let error as StructuredError {
            try finalizeFailureLocked(uuid: uuid, error: error, closeReason: "renderer_error")
        } catch {
            try finalizeFailureLocked(uuid: uuid, error: StructuredError("BACKEND_UNAVAILABLE", error.localizedDescription), closeReason: "renderer_error")
        }
        return waiter
    }

    private func receiveLocked(_ event: RendererEvent) {
        do {
            guard var record = try store.record(uuid: event.uuid), record.state == .live,
                  record.runNumber == event.runNumber, record.workerToken == event.workerToken else { return }
            switch event.kind {
            case .shown:
                guard let index = event.stepIndex, record.definition.steps.indices.contains(index) else { return }
                record.phase = "displaying"
                record.currentStepIndex = index
                record.currentStepShownAt = event.shownAt ?? TimeStamp.string()
                try store.update(record)
                if index == 0 {
                    do {
                        let marker: [String: Any] = ["uuid": record.uuid, "run_number": record.runNumber, "shown_at": record.currentStepShownAt!]
                        let data = try JSONSerialization.data(withJSONObject: marker, options: [.sortedKeys])
                        let old = try store.identities(uuid: record.uuid)["shown_path"]
                        let identity = try AtomicFiles.write(data, to: record.paths.shownPath, allowReplacing: old)
                        try store.setIdentity(uuid: record.uuid, role: "shown_path", path: record.paths.shownPath, identity: identity)
                        waiters.removeValue(forKey: record.uuid)?.finish()
                    } catch let error as StructuredError {
                        record.deliveryError = ResultError(error)
                        try store.update(record)
                        waiters.removeValue(forKey: record.uuid)?.finish(error)
                    }
                }
            case .stepCompleted:
                guard let stepResult = event.stepResult,
                      stepResult.index == record.currentStepIndex,
                      !record.partialResults.contains(where: { $0.index == stepResult.index }) else { return }
                record.partialResults.append(stepResult)
                record.currentStepShownAt = nil
                try store.update(record)
            case .completed:
                guard var result = event.result else { return }
                result.uuid = record.uuid
                result.runNumber = record.runNumber
                record.result = result
                record.deliveryError = ResultError(StructuredError("IO_ERROR", "completion delivery pending", retryable: true))
                record.state = .postRun
                record.phase = "completed"
                record.workerToken = nil
                record.currentStepIndex = nil
                record.currentStepShownAt = nil
                record.partialResults = result.steps
                try store.update(record)
                workers.removeValue(forKey: record.uuid)
                waiters.removeValue(forKey: record.uuid)?.finish(StructuredError("RENDERER_CRASH", "renderer completed without acknowledging presentation"))
                try publishCompletionLocked(uuid: record.uuid)
            case .failed:
                try finalizeFailureLocked(uuid: record.uuid, error: event.error ?? StructuredError("RENDERER_CRASH", "renderer failed"), closeReason: "renderer_error")
            }
        } catch {
            // Stored state remains authoritative; a later recovery pass finalizes live work.
        }
    }

    private func rendererTerminatedLocked(uuid: String, runNumber: Int, token: String, status: Int32) {
        guard let record = try? store.record(uuid: uuid),
              record.state == .live, record.runNumber == runNumber, record.workerToken == token else { return }
        try? finalizeFailureLocked(uuid: uuid, error: StructuredError("RENDERER_CRASH", "renderer exited unexpectedly (status \(status))", retryable: true), closeReason: "renderer_error")
    }

    private func timeoutTriggerLocked(uuid: String, waiter: StartWaiter) -> Bool {
        guard waiters[uuid] === waiter, let record = try? store.record(uuid: uuid), record.state == .live, record.phase == "starting" else { return false }
        workers.removeValue(forKey: uuid)?.stop()
        try? finalizeFailureLocked(uuid: uuid, error: StructuredError("START_TIMEOUT", "renderer startup timed out", retryable: true), closeReason: "timeout")
        return true
    }

    private func statusLocked(_ request: IPCRequest) throws -> IPCResponse {
        guard let uuid = request.uuid else { throw StructuredError("INVALID_ARGUMENT", "--status requires --uuid") }
        guard UUID(uuidString: uuid) != nil else { throw StructuredError("INVALID_ARGUMENT", "malformed UUID") }
        if let record = try store.record(uuid: uuid), isExpired(record) { try endLocked(record, expiry: true) }
        guard let record = try store.record(uuid: uuid) else {
            return try IPCResponse.success(StatusDocument(state: 3, stateName: "gone", phase: "gone", uuid: uuid, runNumber: 0, currentStepIndex: nil, stepCount: 0, createdAt: nil, expiresAt: nil, paths: nil, outcome: nil, error: nil, deliveryError: nil, definitionRevision: nil))
        }
        let document = StatusDocument(
            state: record.state.rawValue, stateName: record.state.name, phase: record.phase, uuid: record.uuid,
            runNumber: record.runNumber, currentStepIndex: record.currentStepIndex, stepCount: record.definition.steps.count,
            createdAt: record.createdAt, expiresAt: record.expiresAt, paths: record.paths,
            outcome: record.result?.outcome, error: record.result?.error, deliveryError: record.deliveryError,
            definitionRevision: record.definitionRevision
        )
        return try IPCResponse.success(document)
    }

    private func finalRecordLocked(_ request: IPCRequest) throws -> InteractionRecord {
        guard let uuid = request.uuid else { throw StructuredError("INVALID_ARGUMENT", "action requires --uuid") }
        let record = try existingRecordLocked(uuid)
        try expireIfNeededLocked(record)
        guard let refreshed = try store.record(uuid: uuid) else { throw StructuredError("NOT_FOUND", "interaction not found") }
        guard refreshed.state == .postRun, refreshed.result != nil else { throw StructuredError("INVALID_STATE", "final results are available only in post_run") }
        return refreshed
    }

    private func rearmLocked(_ request: IPCRequest) throws -> IPCResponse {
        guard let uuid = request.uuid else { throw StructuredError("INVALID_ARGUMENT", "--rearm requires --uuid") }
        var record = try existingRecordLocked(uuid)
        try expireIfNeededLocked(record)
        record = try existingRecordLocked(uuid)
        guard record.state == .postRun else { throw StructuredError("INVALID_STATE", "--rearm requires post_run") }
        if safeProtocolSignalExists(record.paths.exitPath) {
            _ = unlink(record.paths.exitPath)
            try endLocked(record, expiry: false)
            return .empty
        }
        let identities = try store.identities(uuid: uuid)
        for (role, path) in [("response_path", record.paths.responsePath), ("shown_path", record.paths.shownPath), ("user_finished_path", record.paths.userFinishedPath)] {
            try AtomicFiles.removeIfOwned(path, identity: identities[role])
            try store.removeIdentity(uuid: uuid, role: role)
        }
        if safeProtocolSignalExists(record.paths.triggerPath) { _ = unlink(record.paths.triggerPath) }
        record.state = .setup
        record.phase = "idle"
        record.result = nil
        record.deliveryError = nil
        record.workerToken = nil
        record.acceptedAt = nil
        record.currentStepIndex = nil
        record.currentStepShownAt = nil
        record.partialResults = []
        try store.update(record)
        return .empty
    }

    private func extendLocked(_ request: IPCRequest) throws -> IPCResponse {
        guard let uuid = request.uuid else { throw StructuredError("INVALID_ARGUMENT", "--extend requires --uuid") }
        var record = try existingRecordLocked(uuid)
        try expireIfNeededLocked(record)
        record = try existingRecordLocked(uuid)
        let current = TimeStamp.date(record.expiresAt) ?? Date()
        if let addition = try DefinitionValidator.extensionDuration(options: request.options) {
            record.expiresAt = try expirationString(current.addingTimeInterval(TimeInterval(addition)))
        } else {
            record.expiresAt = try expirationString(max(current, Date().addingTimeInterval(TimeInterval(record.initialLifetimeSeconds))))
        }
        try store.update(record)
        return .empty
    }

    private func endRequestLocked(_ request: IPCRequest) throws -> IPCResponse {
        guard let uuid = request.uuid else { throw StructuredError("INVALID_ARGUMENT", "--end requires --uuid") }
        guard UUID(uuidString: uuid) != nil else { throw StructuredError("INVALID_ARGUMENT", "malformed UUID") }
        if let record = try store.record(uuid: uuid) { try endLocked(record, expiry: false) }
        else if let tombstone = try store.tombstones().first(where: { $0.uuid == uuid }) { try clean(tombstone); try store.removeTombstone(uuid: uuid) }
        return .empty
    }

    private func endLocked(_ record: InteractionRecord, expiry: Bool) throws {
        if record.state == .live {
            workers.removeValue(forKey: record.uuid)?.stop()
            waiters.removeValue(forKey: record.uuid)?.finish(StructuredError("NOT_FOUND", expiry ? "interaction expired" : "interaction ended"))
        }
        if safeProtocolSignalExists(record.paths.triggerPath) { _ = unlink(record.paths.triggerPath) }
        if safeProtocolSignalExists(record.paths.exitPath) { _ = unlink(record.paths.exitPath) }
        let tombstone = try store.deleteAndTombstone(record, directory: paths.directory(for: record.uuid).path)
        do { try clean(tombstone); try store.removeTombstone(uuid: record.uuid) }
        catch { if !expiry { throw error } }
    }

    private func clean(_ tombstone: CleanupTombstone) throws {
        for (role, path) in [
            ("uuid_path", tombstone.paths.uuidPath), ("shown_path", tombstone.paths.shownPath),
            ("response_path", tombstone.paths.responsePath), ("user_finished_path", tombstone.paths.userFinishedPath),
        ] {
            try AtomicFiles.removeIfOwned(path, identity: tombstone.identities[role])
        }
        let internalRoot = paths.interactions.standardizedFileURL.path + "/"
        if tombstone.directory.hasPrefix(internalRoot) { try? FileManager.default.removeItem(atPath: tombstone.directory) }
    }

    private func retryTombstonesLocked() throws {
        for tombstone in try store.tombstones() {
            do { try clean(tombstone); try store.removeTombstone(uuid: tombstone.uuid) } catch { continue }
        }
    }

    private func publishCompletionLocked(uuid: String) throws {
        guard var record = try store.record(uuid: uuid), record.state == .postRun, let result = record.result else { return }
        do {
            let identities = try store.identities(uuid: uuid)
            let response = try governorJSONEncoder(pretty: true).encode(result)
            let responseIdentity = try AtomicFiles.write(response, to: record.paths.responsePath, allowReplacing: identities["response_path"])
            try store.setIdentity(uuid: uuid, role: "response_path", path: record.paths.responsePath, identity: responseIdentity)
            let markerObject: [String: Any] = ["uuid": uuid, "run_number": record.runNumber, "finished_at": result.finishedAt]
            let marker = try JSONSerialization.data(withJSONObject: markerObject, options: [.sortedKeys])
            let finishedIdentity = try AtomicFiles.write(marker, to: record.paths.userFinishedPath, allowReplacing: identities["user_finished_path"])
            try store.setIdentity(uuid: uuid, role: "user_finished_path", path: record.paths.userFinishedPath, identity: finishedIdentity)
            record.deliveryError = nil
            try store.update(record)
        } catch let error as StructuredError {
            record.deliveryError = ResultError(error)
            try store.update(record)
            throw error
        }
    }

    private func finalizeFailureLocked(uuid: String, error: StructuredError, closeReason: String) throws {
        guard var record = try store.record(uuid: uuid), record.state == .live else { return }
        let now = Date()
        var results = record.partialResults.sorted { $0.index < $1.index }
        let active = max(record.currentStepIndex ?? 0, results.count)
        if record.definition.steps.indices.contains(active), !results.contains(where: { $0.index == active }) {
            var failed = StepResult(index: active, uiType: record.definition.steps[active].uiType, outcome: "failed")
            failed.closeReason = closeReason
            failed.shownAt = record.currentStepShownAt
            failed.finishedAt = TimeStamp.string(now)
            if let shown = record.currentStepShownAt.flatMap(TimeStamp.date) { failed.length = milliseconds(now.timeIntervalSince(shown)) }
            failed.error = ResultError(error)
            results.append(failed)
        }
        for index in record.definition.steps.indices where !results.contains(where: { $0.index == index }) {
            var skipped = StepResult(index: index, uiType: record.definition.steps[index].uiType, outcome: "skipped")
            skipped.skipReason = "previous_step_stopped"
            results.append(skipped)
        }
        let started = results.compactMap(\.shownAt).first
        let length = started.flatMap(TimeStamp.date).map { milliseconds(now.timeIntervalSince($0)) }
        record.result = ResultDocument(uuid: uuid, runNumber: record.runNumber, outcome: "failed", startedAt: started, finishedAt: TimeStamp.string(now), length: length, error: ResultError(error), steps: results.sorted { $0.index < $1.index })
        record.deliveryError = ResultError(StructuredError("IO_ERROR", "completion delivery pending", retryable: true))
        record.state = .postRun
        record.phase = "completed"
        record.workerToken = nil
        record.currentStepIndex = nil
        record.currentStepShownAt = nil
        record.partialResults = results
        try store.update(record)
        workers.removeValue(forKey: uuid)
        waiters.removeValue(forKey: uuid)?.finish(error)
        try? publishCompletionLocked(uuid: uuid)
    }

    private func recoverLocked() throws {
        for record in try store.allRecords() {
            if isExpired(record) { try endLocked(record, expiry: true) }
            else if record.state == .live {
                try finalizeFailureLocked(uuid: record.uuid, error: StructuredError("RENDERER_CRASH", "service restarted during an active interaction", retryable: true), closeReason: "renderer_error")
            } else if record.state == .postRun, record.deliveryError != nil {
                try? publishCompletionLocked(uuid: record.uuid)
            }
        }
        try retryTombstonesLocked()
    }

    private func existingRecordLocked(_ uuid: String) throws -> InteractionRecord {
        guard UUID(uuidString: uuid) != nil else { throw StructuredError("INVALID_ARGUMENT", "malformed UUID") }
        guard let record = try store.record(uuid: uuid) else { throw StructuredError("NOT_FOUND", "interaction not found") }
        guard record.ownerUid == getuid() else { throw StructuredError("NOT_FOUND", "interaction not found") }
        return record
    }

    private func mutableSetupRecord(_ request: IPCRequest) throws -> InteractionRecord {
        guard let uuid = request.uuid else { throw StructuredError("INVALID_ARGUMENT", "action requires --uuid") }
        let record = try existingRecordLocked(uuid)
        try expireIfNeededLocked(record)
        guard let refreshed = try store.record(uuid: uuid), refreshed.state == .setup else { throw StructuredError("INVALID_STATE", "interaction is not in setup") }
        return refreshed
    }

    private func expireIfNeededLocked(_ record: InteractionRecord) throws {
        if isExpired(record) { try endLocked(record, expiry: true); throw StructuredError("NOT_FOUND", "interaction expired") }
    }

    private func expirationString(_ date: Date) throws -> String {
        // The persisted ISO-8601 format uses a four-digit year (through 9999).
        guard date.timeIntervalSince1970 < 253_402_300_800 else {
            throw StructuredError("INVALID_ARGUMENT", "lifetime exceeds the supported calendar range")
        }
        let encoded = TimeStamp.string(date)
        guard TimeStamp.date(encoded) != nil else {
            throw StructuredError("INVALID_ARGUMENT", "lifetime cannot be represented")
        }
        return encoded
    }

    private func isExpired(_ record: InteractionRecord) -> Bool {
        guard let expiry = TimeStamp.date(record.expiresAt) else { return true }
        return Date() >= expiry
    }

    private func preflight(_ definition: InteractionDefinition) throws {
        for step in definition.steps {
            if step.uiType == .file, let directory = step.directory {
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: directory, isDirectory: &isDirectory), isDirectory.boolValue,
                      FileManager.default.isReadableFile(atPath: directory) else { throw StructuredError("INVALID_ARGUMENT", "file picker directory is missing or unreadable") }
            }
            if step.uiType == .media, let path = step.path {
                var info = stat()
                guard lstat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { throw StructuredError("UNSUPPORTED_MEDIA", "media path is not an existing regular file") }
            }
        }
    }

    private func applyUpdate(options: [String: [String]], flags: Set<String>, resets: [String], workingDirectory: String, step: inout StepDefinition) throws {
        let supported = Set(["title", "message", "button", "mode", "directory", "filter", "filename", "media-type", "path", "volume", "plays", "auto-close", "entry-type", "default", "max-length", "min", "max", "confirm-label", "cancel-label"])
        if let unknown = options.keys.first(where: { !supported.contains($0) }) { throw StructuredError("INVALID_ARGUMENT", "--\(unknown) is not valid for update") }
        for reset in resets {
            switch reset {
            case "title": step.title = nil
            case "button": step.button = nil; step.buttons = []
            case "directory": step.directory = nil
            case "filter": step.filters = []
            case "filename": step.filename = nil
            case "volume": step.volume = nil
            case "plays": step.plays = nil
            case "forever": step.forever = false
            case "auto-close": step.autoClose = nil
            case "message" where step.uiType == .entry: step.message = nil
            case "default": step.defaultValue = nil
            case "required": step.required = false
            case "max-length": step.maxLength = nil
            case "min": step.min = nil
            case "max": step.max = nil
            case "confirm-label": step.confirmLabel = nil
            case "cancel-label": step.cancelLabel = nil
            default: throw StructuredError("INVALID_ARGUMENT", "--\(reset) cannot be reset for this interaction")
            }
        }
        if let value = options["title"]?.last { step.title = value }
        if let value = options["message"]?.last { step.message = value }
        if let values = options["button"] { step.button = values.last; step.buttons = values }
        if let value = options["mode"]?.last { step.mode = value.lowercased() }
        if let value = options["directory"]?.last { step.directory = absolutePath(value, relativeTo: workingDirectory) }
        if let values = options["filter"] { step.filters = values }
        if let value = options["filename"]?.last { step.filename = value }
        if let value = options["media-type"]?.last { step.mediaType = value.lowercased() }
        if let value = options["path"]?.last { step.path = absolutePath(value, relativeTo: workingDirectory) }
        if let value = options["volume"]?.last { guard let parsed = Int(value) else { throw StructuredError("INVALID_ARGUMENT", "--volume must be a whole number") }; step.volume = parsed }
        if let value = options["plays"]?.last { guard let parsed = Int(value) else { throw StructuredError("INVALID_ARGUMENT", "--plays must be a whole number") }; step.plays = parsed }
        if let value = options["auto-close"]?.last { guard let parsed = Double(value), parsed.isFinite, parsed > 0 else { throw StructuredError("INVALID_ARGUMENT", "--auto-close must be positive") }; step.autoClose = parsed }
        if let value = options["entry-type"]?.last { step.entryType = value.lowercased() }
        if let value = options["default"]?.last { step.defaultValue = value }
        if let value = options["max-length"]?.last { guard let parsed = Int(value) else { throw StructuredError("INVALID_ARGUMENT", "--max-length must be a whole number") }; step.maxLength = parsed }
        if let value = options["min"]?.last { step.min = value }
        if let value = options["max"]?.last { step.max = value }
        if let value = options["confirm-label"]?.last { step.confirmLabel = value }
        if let value = options["cancel-label"]?.last { step.cancelLabel = value }
        if flags.contains("required") { step.required = true }
        if flags.contains("forever") { step.forever = true }
    }

    private func parsePositiveTimeout(_ value: String?, defaultValue: Double) throws -> Double {
        guard let value else { return defaultValue }
        guard let result = Double(value), result.isFinite, result > 0 else { throw StructuredError("INVALID_ARGUMENT", "timeout must be positive") }
        return result
    }
}

public func milliseconds(_ value: TimeInterval) -> Double {
    max(0, (value * 1000).rounded() / 1000)
}
