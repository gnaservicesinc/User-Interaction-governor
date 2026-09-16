import Darwin
import Foundation
import GovernorCore

private func write(_ data: Data, to handle: FileHandle) { try? handle.write(contentsOf: data) }
private func stdout(_ string: String) { write(Data(string.utf8), to: .standardOutput) }
private func stderr(_ string: String) { write(Data(string.utf8), to: .standardError) }

private func requestsJSONErrors(_ arguments: [String]) -> Bool {
    if arguments.contains("--error-format=json") || arguments.contains("--error_format=json") { return true }
    for index in arguments.indices where arguments[index] == "--error-format" || arguments[index] == "--error_format" {
        if arguments.indices.contains(index + 1), arguments[index + 1].lowercased() == "json" { return true }
    }
    return false
}

private func fail(_ error: StructuredError, json: Bool) -> Never {
    if json, let data = try? governorJSONEncoder().encode(error) {
        write(data + Data([0x0A]), to: .standardError)
    } else {
        stderr("uig: \(error.message)\n")
        if error.code == "INVALID_ARGUMENT" { stderr("Try 'uig --help' for usage.\n") }
    }
    exit(error.exitCode)
}

private func validateSyntax(_ parsed: ParsedArguments) throws {
    guard let action = parsed.action else { return }
    let common = Set(["uuid", "error-format"])
    let step = Set(["ui-type", "title", "message", "button", "mode", "directory", "filter", "filename", "media-type", "path", "volume", "plays", "auto-close", "entry-type", "default", "max-length", "min", "max", "confirm-label", "cancel-label"])
    let protocolOptions = Set(["trigger-path", "shown-path", "user-finished-path", "response-path", "response-format", "exit-path", "uuid-path"])
    let duration = Set(["days", "hours", "seconds"])
    let allowed: Set<String>
    let allowedFlags: Set<String>
    switch action {
    case .new: allowed = step.union(protocolOptions).union(duration).union(common); allowedFlags = ["required", "forever"]
    case .stack: allowed = step.union(common); allowedFlags = ["required", "forever"]
    case .update: allowed = step.subtracting(["ui-type"]).union(common).union(["reset"]); allowedFlags = ["required", "forever"]
    case .trigger: allowed = common.union(["start-timeout", "timeout"]); allowedFlags = ["wait"]
    case .status: allowed = common.union(["format", "timeout"]); allowedFlags = ["wait"]
    case .dump: allowed = common.union(["output"]); allowedFlags = []
    case .get: allowed = common.union(["field", "step", "format", "output"]); allowedFlags = []
    case .extend: allowed = common.union(duration); allowedFlags = []
    case .rearm, .end: allowed = common; allowedFlags = []
    }
    if let invalid = parsed.options.keys.first(where: { !allowed.contains($0) }) { throw StructuredError("INVALID_ARGUMENT", "--\(invalid) is not valid with --\(action.rawValue)") }
    if let invalid = parsed.flags.first(where: { !allowedFlags.contains($0) }) { throw StructuredError("INVALID_ARGUMENT", "--\(invalid) is not valid with --\(action.rawValue)") }
    if action == .new {
        guard parsed.value("uuid") == nil else { throw StructuredError("INVALID_ARGUMENT", "--new does not accept --uuid") }
    } else {
        guard let uuid = parsed.value("uuid"), UUID(uuidString: uuid) != nil else { throw StructuredError("INVALID_ARGUMENT", "--\(action.rawValue) requires a well-formed --uuid") }
    }
    if action != .update, !parsed.resets.isEmpty {
        throw StructuredError("INVALID_ARGUMENT", "--reset is valid only with --update")
    }
    if action == .get, parsed.value("field") == nil { throw StructuredError("INVALID_ARGUMENT", "--get requires --field") }
    if let format = parsed.value("format") {
        let supported = action == .status ? ["json"] : ["raw", "json"]
        guard supported.contains(format.lowercased()) else { throw StructuredError("INVALID_ARGUMENT", "unsupported --format for this action") }
    }
    if let step = parsed.value("step"), Int(step) == nil { throw StructuredError("INVALID_ARGUMENT", "--step must be a zero-based whole number") }
    for timeout in [parsed.value("timeout"), parsed.value("start-timeout")].compactMap({ $0 }) {
        guard let number = Double(timeout), number.isFinite, number > 0 else { throw StructuredError("INVALID_ARGUMENT", "timeouts must be positive") }
    }
}

private func request(_ parsed: ParsedArguments, action: GovernorAction? = nil) -> IPCRequest {
    var forwarded = parsed.options
    for local in ["uuid", "error-format", "timeout", "format", "field", "step", "output"] { forwarded.removeValue(forKey: local) }
    return IPCRequest(
        action: action ?? parsed.action!, uuid: parsed.value("uuid"), options: forwarded,
        flags: Array(parsed.flags), reset: parsed.resets,
        workingDirectory: FileManager.default.currentDirectoryPath, sessionId: currentSessionID()
    )
}

private func checked(_ response: IPCResponse, errorJSON: Bool) -> Data {
    guard response.ok else { fail(response.error ?? StructuredError("IO_ERROR", "unknown service error"), json: errorJSON) }
    return response.payload ?? Data()
}

private func status(_ uuid: String, client: IPCClient, errorJSON: Bool) -> StatusDocument {
    let request = IPCRequest(action: .status, uuid: uuid, options: [:], flags: [], reset: [], workingDirectory: FileManager.default.currentDirectoryPath, sessionId: currentSessionID())
    let data: Data
    do { data = checked(try client.send(request), errorJSON: errorJSON) }
    catch let error as StructuredError { fail(error, json: errorJSON) }
    catch { fail(StructuredError("IO_ERROR", error.localizedDescription), json: errorJSON) }
    guard let document = try? governorJSONDecoder().decode(StatusDocument.self, from: data) else { fail(StructuredError("IO_ERROR", "invalid status response"), json: errorJSON) }
    return document
}

private func waitUntilNotLive(uuid: String, timeout: Double?, client: IPCClient, errorJSON: Bool) -> StatusDocument {
    let started = ProcessInfo.processInfo.systemUptime
    while true {
        let document = status(uuid, client: client, errorJSON: errorJSON)
        if document.state != PublicState.live.rawValue { return document }
        if let timeout, ProcessInfo.processInfo.systemUptime - started >= timeout { exit(124) }
        usleep(100_000)
    }
}

private enum SelectedValue {
    case string(String?), integer(Int?), double(Double?), boolean(Bool?), object(ResultError?)

    func data(format: String) throws -> Data {
        if format == "raw" {
            switch self {
            case .string(let value): guard let value else { throw unavailable() }; return Data((value + "\n").utf8)
            case .integer(let value): guard let value else { throw unavailable() }; return Data((String(value) + "\n").utf8)
            case .double(let value): guard let value else { throw unavailable() }; return Data((String(value) + "\n").utf8)
            case .boolean(let value): guard let value else { throw unavailable() }; return Data(((value ? "true" : "false") + "\n").utf8)
            case .object: throw StructuredError("FIELD_UNAVAILABLE", "arrays and objects require JSON format")
            }
        }
        let object: Any
        switch self {
        case .string(let value): object = value ?? NSNull()
        case .integer(let value): object = value ?? NSNull()
        case .double(let value): object = value ?? NSNull()
        case .boolean(let value): object = value ?? NSNull()
        case .object(let value):
            guard let value else { object = NSNull(); break }
            return try governorJSONEncoder().encode(value) + Data([0x0A])
        }
        return try JSONSerialization.data(withJSONObject: object, options: [.fragmentsAllowed]) + Data([0x0A])
    }

    private func unavailable() -> StructuredError { StructuredError("FIELD_UNAVAILABLE", "field is null; use JSON format to preserve null") }
}

private func select(field rawField: String, step requestedStep: Int?, from result: ResultDocument) throws -> SelectedValue {
    let field = rawField.replacingOccurrences(of: "-", with: "_").lowercased()
    let topFields = Set(["outcome", "started_at", "finished_at", "length", "run_number", "error"])
    let stepFields = Set(["index", "ui_type", "outcome", "close_reason", "status", "shown_at", "finished_at", "length", "button_number", "button_string", "file_path", "media_type", "loops_ran", "escaped", "value", "confirmed", "skip_reason", "error"])
    if requestedStep == nil && topFields.contains(field) {
        switch field {
        case "outcome": return .string(result.outcome)
        case "started_at": return .string(result.startedAt)
        case "finished_at": return .string(result.finishedAt)
        case "length": return .double(result.length)
        case "run_number": return .integer(result.runNumber)
        case "error": return .object(result.error)
        default: break
        }
    }
    guard stepFields.contains(field) else { throw StructuredError("FIELD_UNAVAILABLE", "unknown result field: \(rawField)") }
    let index: Int
    if let requestedStep { index = requestedStep }
    else if result.steps.count == 1 { index = 0 }
    else { throw StructuredError("FIELD_UNAVAILABLE", "--step is required for a stacked interaction") }
    guard result.steps.indices.contains(index) else { throw StructuredError("FIELD_UNAVAILABLE", "step index is out of range") }
    let step = result.steps[index]
    switch field {
    case "index": return .integer(step.index)
    case "ui_type": return .string(step.uiType.rawValue)
    case "outcome": return .string(step.outcome)
    case "close_reason": return .string(step.closeReason)
    case "status": return .integer(step.status)
    case "shown_at": return .string(step.shownAt)
    case "finished_at": return .string(step.finishedAt)
    case "length": return .double(step.length)
    case "button_number": return .integer(step.buttonNumber)
    case "button_string": return .string(step.buttonString)
    case "file_path": return .string(step.filePath)
    case "media_type": return .string(step.mediaType)
    case "loops_ran": return .integer(step.loopsRan)
    case "escaped": return .boolean(step.escaped)
    case "value": return .string(step.value)
    case "confirmed": return .boolean(step.confirmed)
    case "skip_reason": return .string(step.skipReason)
    case "error": return .object(step.error)
    default: throw StructuredError("FIELD_UNAVAILABLE", "unknown result field: \(rawField)")
    }
}

private func emit(_ data: Data, output: String?, uuid: String, client: IPCClient, errorJSON: Bool) {
    guard let output else { write(data, to: .standardOutput); return }
    let path = absolutePath(output, relativeTo: FileManager.default.currentDirectoryPath)
    let document = status(uuid, client: client, errorJSON: errorJSON)
    if let paths = document.paths, paths.all.contains(where: { pathReservationKey($0.path) == pathReservationKey(path) }) { fail(StructuredError("PATH_CONFLICT", "--output cannot target a protocol file"), json: errorJSON) }
    do { _ = try AtomicFiles.write(data, to: path, requirePrivateParent: false) }
    catch let error as StructuredError { fail(error, json: errorJSON) }
    catch { fail(StructuredError("IO_ERROR", error.localizedDescription), json: errorJSON) }
}

if CommandLine.argc > 1 {
    for index in 1..<Int(CommandLine.argc) {
        guard let pointer = CommandLine.unsafeArgv[index], String(validatingUTF8: pointer) != nil else {
            fail(StructuredError("INVALID_ARGUMENT", "arguments and paths must be valid UTF-8"), json: false)
        }
    }
}
let arguments = Array(CommandLine.arguments.dropFirst())
let parsed: ParsedArguments
do { parsed = try ArgumentParser.parse(arguments) }
catch let error as StructuredError { fail(error, json: requestsJSONErrors(arguments)) }
catch { fail(StructuredError("INVALID_ARGUMENT", error.localizedDescription), json: false) }

if arguments.isEmpty || parsed.help { stdout(uigUsage + "\n"); exit(0) }
if parsed.version { stdout("uig \(governorVersion)\n"); exit(0) }
guard parsed.action != nil else { stdout(uigUsage + "\n"); exit(0) }
let errorJSON = parsed.value("error-format")?.lowercased() == "json"
do { try validateSyntax(parsed) }
catch let error as StructuredError { fail(error, json: errorJSON) }
catch { fail(StructuredError("INVALID_ARGUMENT", error.localizedDescription), json: errorJSON) }

let client = IPCClient()
let response: IPCResponse
do { response = try client.send(request(parsed)) }
catch let error as StructuredError { fail(error, json: errorJSON) }
catch { fail(StructuredError("IO_ERROR", error.localizedDescription), json: errorJSON) }
let payload = checked(response, errorJSON: errorJSON)
let action = parsed.action!
let uuid = parsed.value("uuid")

switch action {
case .new:
    guard let assigned = try? governorJSONDecoder().decode(String.self, from: payload) else { fail(StructuredError("IO_ERROR", "invalid create response"), json: errorJSON) }
    stdout(assigned + "\n")
case .status:
    var document: StatusDocument
    guard let initial = try? governorJSONDecoder().decode(StatusDocument.self, from: payload) else { fail(StructuredError("IO_ERROR", "invalid status response"), json: errorJSON) }
    document = initial
    if parsed.has("wait"), document.state == PublicState.live.rawValue {
        document = waitUntilNotLive(uuid: uuid!, timeout: parsed.value("timeout").flatMap(Double.init), client: client, errorJSON: errorJSON)
    }
    if parsed.value("format")?.lowercased() == "json" {
        guard let data = try? governorJSONEncoder(pretty: true).encode(document) else { fail(StructuredError("IO_ERROR", "cannot serialize status"), json: errorJSON) }
        write(data + Data([0x0A]), to: .standardOutput)
    } else { stdout("\(document.state)\n") }
case .trigger:
    if parsed.has("wait") {
        let document = waitUntilNotLive(uuid: uuid!, timeout: parsed.value("timeout").flatMap(Double.init), client: client, errorJSON: errorJSON)
        if document.state == PublicState.gone.rawValue { fail(StructuredError("NOT_FOUND", "interaction ended while waiting"), json: errorJSON) }
        if let delivery = document.deliveryError { fail(StructuredError(delivery.code, delivery.message, retryable: delivery.retryable), json: errorJSON) }
        if document.outcome == "failed", let operation = document.error { fail(StructuredError(operation.code, operation.message, retryable: operation.retryable), json: errorJSON) }
    }
case .dump:
    var data = payload
    if data.last != 0x0A { data.append(0x0A) }
    emit(data, output: parsed.value("output"), uuid: uuid!, client: client, errorJSON: errorJSON)
case .get:
    guard let result = try? governorJSONDecoder().decode(ResultDocument.self, from: payload) else { fail(StructuredError("IO_ERROR", "invalid result response"), json: errorJSON) }
    do {
        let selected = try select(field: parsed.value("field")!, step: parsed.value("step").flatMap(Int.init), from: result)
        let data = try selected.data(format: parsed.value("format")?.lowercased() ?? "raw")
        emit(data, output: parsed.value("output"), uuid: uuid!, client: client, errorJSON: errorJSON)
    } catch let error as StructuredError { fail(error, json: errorJSON) }
    catch { fail(StructuredError("FIELD_UNAVAILABLE", error.localizedDescription), json: errorJSON) }
case .stack, .update, .rearm, .extend, .end:
    break
}
