import Foundation

public let governorVersion = "1.0.0"
public let schemaVersion = 1

public enum PublicState: Int, Codable, Sendable {
    case setup = 0
    case live = 1
    case postRun = 2
    case gone = 3

    public var name: String {
        switch self {
        case .setup: return "setup"
        case .live: return "live"
        case .postRun: return "post_run"
        case .gone: return "gone"
        }
    }
}

public enum UIType: String, Codable, CaseIterable, Sendable {
    case display, choice, file, media, entry, confirm
}

public enum GovernorAction: String, Codable, CaseIterable, Sendable {
    case new, stack, update, trigger, rearm, status, dump, get, extend, end
}

public struct StructuredError: Codable, LocalizedError, Sendable, Equatable {
    public let code: String
    public let message: String
    public let retryable: Bool

    public init(_ code: String, _ message: String, retryable: Bool = false) {
        self.code = code
        self.message = message
        self.retryable = retryable
    }

    public var errorDescription: String? { message }

    public var exitCode: Int32 {
        switch code {
        case "INVALID_ARGUMENT": return 2
        case "NOT_FOUND": return 3
        case "INVALID_STATE", "BUSY": return 4
        case "NO_DISPLAY", "BACKEND_UNAVAILABLE", "START_TIMEOUT", "UNSUPPORTED_MEDIA", "RENDERER_CRASH": return 5
        case "IO_ERROR", "PATH_CONFLICT": return 6
        case "FIELD_UNAVAILABLE": return 7
        default: return 5
        }
    }
}

public struct ProtocolPaths: Codable, Sendable, Equatable {
    public var triggerPath: String
    public var shownPath: String
    public var userFinishedPath: String
    public var responsePath: String
    public var exitPath: String
    public var uuidPath: String

    public var all: [(role: String, path: String)] {
        [
            ("trigger_path", triggerPath), ("shown_path", shownPath),
            ("user_finished_path", userFinishedPath), ("response_path", responsePath),
            ("exit_path", exitPath), ("uuid_path", uuidPath),
        ]
    }
}

public struct StepDefinition: Codable, Sendable, Equatable {
    public var uiType: UIType
    public var title: String?
    public var message: String?
    public var button: String?
    public var buttons: [String]
    public var mode: String?
    public var directory: String?
    public var filters: [String]
    public var filename: String?
    public var mediaType: String?
    public var path: String?
    public var volume: Int?
    public var plays: Int?
    public var forever: Bool
    public var autoClose: Double?
    public var width: Int?
    public var height: Int?
    public var entryType: String?
    public var defaultValue: String?
    public var required: Bool
    public var maxLength: Int?
    public var min: String?
    public var max: String?
    public var confirmLabel: String?
    public var cancelLabel: String?

    public init(uiType: UIType) {
        self.uiType = uiType
        buttons = []
        filters = []
        forever = false
        required = false
    }
}

public struct InteractionDefinition: Codable, Sendable, Equatable {
    public var steps: [StepDefinition]

    public init(steps: [StepDefinition]) {
        self.steps = steps
    }
}

public struct ResultError: Codable, Sendable, Equatable {
    public let code: String
    public let message: String
    public let retryable: Bool

    public init(_ error: StructuredError) {
        code = error.code
        message = error.message
        retryable = error.retryable
    }
}

public struct StepResult: Codable, Sendable, Equatable {
    public var index: Int
    public var uiType: UIType
    public var outcome: String
    public var closeReason: String?
    public var status: Int?
    public var shownAt: String?
    public var finishedAt: String?
    public var length: Double?
    public var buttonNumber: Int?
    public var buttonString: String?
    public var filePath: String?
    public var mediaType: String?
    public var loopsRan: Int?
    public var escaped: Bool?
    public var value: String?
    public var confirmed: Bool?
    public var skipReason: String?
    public var error: ResultError?

    public init(index: Int, uiType: UIType, outcome: String) {
        self.index = index
        self.uiType = uiType
        self.outcome = outcome
    }

    private enum CodingKeys: String, CodingKey {
        case index, uiType, outcome, closeReason, status, shownAt, finishedAt, length
        case buttonNumber, buttonString, filePath, mediaType, loopsRan, escaped, value, confirmed
        case skipReason, error
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        index = try values.decode(Int.self, forKey: .index)
        uiType = try values.decode(UIType.self, forKey: .uiType)
        outcome = try values.decode(String.self, forKey: .outcome)
        closeReason = try values.decodeIfPresent(String.self, forKey: .closeReason)
        status = try values.decodeIfPresent(Int.self, forKey: .status)
        shownAt = try values.decodeIfPresent(String.self, forKey: .shownAt)
        finishedAt = try values.decodeIfPresent(String.self, forKey: .finishedAt)
        length = try values.decodeIfPresent(Double.self, forKey: .length)
        buttonNumber = try values.decodeIfPresent(Int.self, forKey: .buttonNumber)
        buttonString = try values.decodeIfPresent(String.self, forKey: .buttonString)
        filePath = try values.decodeIfPresent(String.self, forKey: .filePath)
        mediaType = try values.decodeIfPresent(String.self, forKey: .mediaType)
        loopsRan = try values.decodeIfPresent(Int.self, forKey: .loopsRan)
        escaped = try values.decodeIfPresent(Bool.self, forKey: .escaped)
        value = try values.decodeIfPresent(String.self, forKey: .value)
        confirmed = try values.decodeIfPresent(Bool.self, forKey: .confirmed)
        skipReason = try values.decodeIfPresent(String.self, forKey: .skipReason)
        error = try values.decodeIfPresent(ResultError.self, forKey: .error)
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(index, forKey: .index)
        try values.encode(uiType, forKey: .uiType)
        try values.encode(outcome, forKey: .outcome)
        try values.encodeOptional(closeReason, forKey: .closeReason)
        try values.encodeOptional(status, forKey: .status)
        try values.encodeOptional(shownAt, forKey: .shownAt)
        try values.encodeOptional(finishedAt, forKey: .finishedAt)
        try values.encodeOptional(length, forKey: .length)
        switch uiType {
        case .choice:
            try values.encodeOptional(buttonNumber, forKey: .buttonNumber)
            try values.encodeOptional(buttonString, forKey: .buttonString)
        case .file:
            try values.encodeOptional(filePath, forKey: .filePath)
        case .media:
            try values.encodeOptional(mediaType, forKey: .mediaType)
            try values.encodeOptional(loopsRan, forKey: .loopsRan)
            try values.encodeOptional(escaped, forKey: .escaped)
        case .entry:
            try values.encodeOptional(value, forKey: .value)
        case .confirm:
            try values.encodeOptional(confirmed, forKey: .confirmed)
        case .display:
            break
        }
        if outcome == "skipped" { try values.encodeOptional(skipReason, forKey: .skipReason) }
        try values.encodeOptional(error, forKey: .error)
    }
}

public struct ResultDocument: Codable, Sendable, Equatable {
    public var schemaVersion: Int = 1
    public var uuid: String
    public var runNumber: Int
    public var state: String = "post_run"
    public var outcome: String
    public var startedAt: String?
    public var finishedAt: String
    public var length: Double?
    public var error: ResultError?
    public var steps: [StepResult]

    public init(uuid: String, runNumber: Int, outcome: String, startedAt: String?, finishedAt: String, length: Double?, error: ResultError?, steps: [StepResult]) {
        self.uuid = uuid
        self.runNumber = runNumber
        self.outcome = outcome
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.length = length
        self.error = error
        self.steps = steps
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, uuid, runNumber, state, outcome, startedAt, finishedAt, length, error, steps
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try values.decode(Int.self, forKey: .schemaVersion)
        uuid = try values.decode(String.self, forKey: .uuid)
        runNumber = try values.decode(Int.self, forKey: .runNumber)
        state = try values.decode(String.self, forKey: .state)
        outcome = try values.decode(String.self, forKey: .outcome)
        startedAt = try values.decodeIfPresent(String.self, forKey: .startedAt)
        finishedAt = try values.decode(String.self, forKey: .finishedAt)
        length = try values.decodeIfPresent(Double.self, forKey: .length)
        error = try values.decodeIfPresent(ResultError.self, forKey: .error)
        steps = try values.decode([StepResult].self, forKey: .steps)
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(schemaVersion, forKey: .schemaVersion)
        try values.encode(uuid, forKey: .uuid)
        try values.encode(runNumber, forKey: .runNumber)
        try values.encode(state, forKey: .state)
        try values.encode(outcome, forKey: .outcome)
        try values.encodeOptional(startedAt, forKey: .startedAt)
        try values.encode(finishedAt, forKey: .finishedAt)
        try values.encodeOptional(length, forKey: .length)
        try values.encodeOptional(error, forKey: .error)
        try values.encode(steps, forKey: .steps)
    }
}

private extension KeyedEncodingContainer {
    mutating func encodeOptional<T: Encodable>(_ value: T?, forKey key: Key) throws {
        if let value { try encode(value, forKey: key) }
        else { try encodeNil(forKey: key) }
    }
}

public struct InteractionRecord: Codable, Sendable, Equatable {
    public var schemaVersion: Int
    public var uuid: String
    public var ownerUid: UInt32
    public var sessionId: String
    public var createdAt: String
    public var initialLifetimeSeconds: Int
    public var expiresAt: String
    public var definitionRevision: Int
    public var runNumber: Int
    public var state: PublicState
    public var phase: String
    public var stackLocked: Bool
    public var definition: InteractionDefinition
    public var paths: ProtocolPaths
    public var explicitlyRequestedUuidPath: Bool
    public var result: ResultDocument?
    public var deliveryError: ResultError?
    public var workerToken: String?
    public var acceptedAt: String?
    public var currentStepIndex: Int?
    public var currentStepShownAt: String?
    public var partialResults: [StepResult]
}

public struct StatusDocument: Codable, Sendable {
    public var schemaVersion: Int = 1
    public var state: Int
    public var stateName: String
    public var phase: String
    public var uuid: String
    public var runNumber: Int
    public var currentStepIndex: Int?
    public var stepCount: Int
    public var createdAt: String?
    public var expiresAt: String?
    public var paths: ProtocolPaths?
    public var outcome: String?
    public var error: ResultError?
    public var deliveryError: ResultError?
    public var definitionRevision: Int?
}

public struct IPCRequest: Codable, Sendable {
    public var action: GovernorAction
    public var uuid: String?
    public var options: [String: [String]]
    public var flags: [String]
    public var reset: [String]
    public var workingDirectory: String
    public var sessionId: String

    public init(action: GovernorAction, uuid: String?, options: [String: [String]], flags: [String], reset: [String], workingDirectory: String, sessionId: String) {
        self.action = action
        self.uuid = uuid
        self.options = options
        self.flags = flags
        self.reset = reset
        self.workingDirectory = workingDirectory
        self.sessionId = sessionId
    }
}

public struct IPCResponse: Codable, Sendable {
    public var ok: Bool
    public var payload: Data?
    public var error: StructuredError?

    public static func success<T: Encodable>(_ value: T) throws -> IPCResponse {
        IPCResponse(ok: true, payload: try governorJSONEncoder().encode(value), error: nil)
    }

    public static var empty: IPCResponse { IPCResponse(ok: true, payload: Data(), error: nil) }
    public static func failure(_ error: StructuredError) -> IPCResponse { IPCResponse(ok: false, payload: nil, error: error) }
}

public struct RendererRequest: Codable, Sendable {
    public var schemaVersion: Int = 1
    public var uuid: String
    public var runNumber: Int
    public var workerToken: String
    public var steps: [StepDefinition]

    public init(uuid: String, runNumber: Int, workerToken: String, steps: [StepDefinition]) {
        self.uuid = uuid
        self.runNumber = runNumber
        self.workerToken = workerToken
        self.steps = steps
    }
}

public enum RendererEventKind: String, Codable, Sendable { case shown, stepCompleted, completed, failed }

public struct RendererEvent: Codable, Sendable {
    public var schemaVersion: Int = 1
    public var kind: RendererEventKind
    public var uuid: String
    public var runNumber: Int
    public var workerToken: String
    public var stepIndex: Int?
    public var shownAt: String?
    public var stepResult: StepResult?
    public var result: ResultDocument?
    public var error: StructuredError?

    public init(kind: RendererEventKind, uuid: String, runNumber: Int, workerToken: String, stepIndex: Int?, shownAt: String?, stepResult: StepResult?, result: ResultDocument?, error: StructuredError?) {
        self.kind = kind
        self.uuid = uuid
        self.runNumber = runNumber
        self.workerToken = workerToken
        self.stepIndex = stepIndex
        self.shownAt = shownAt
        self.stepResult = stepResult
        self.result = result
        self.error = error
    }
}

public func governorJSONEncoder(pretty: Bool = false) -> JSONEncoder {
    let encoder = JSONEncoder()
    encoder.keyEncodingStrategy = .convertToSnakeCase
    if pretty { encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes] }
    return encoder
}

public func governorJSONDecoder() -> JSONDecoder {
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    return decoder
}

public enum TimeStamp {
    private static let formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }()

    public static func string(_ date: Date = Date()) -> String { formatter.string(from: date) }
    public static func date(_ string: String) -> Date? { formatter.date(from: string) }
}
