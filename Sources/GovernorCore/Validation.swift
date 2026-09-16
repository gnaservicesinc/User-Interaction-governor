import Darwin
import Foundation

public enum DefinitionValidator {
    public static let maximumSteps = 100
    public static let maximumChoiceButtons = 32
    public static let maximumDefinitionBytes = 1_048_576

    public static func parseUIType(_ value: String?) throws -> UIType {
        guard let value, let type = UIType(rawValue: value.lowercased()) else {
            throw StructuredError("INVALID_ARGUMENT", "--ui-type must be display, choice, file, media, entry, or confirm")
        }
        return type
    }

    public static func step(options: [String: [String]], flags: Set<String>, workingDirectory: String) throws -> StepDefinition {
        let type = try parseUIType(options["ui-type"]?.last)
        var step = StepDefinition(uiType: type)
        step.title = options["title"]?.last
        step.message = options["message"]?.last
        step.button = options["button"]?.last
        step.buttons = options["button"] ?? []
        step.mode = options["mode"]?.last?.lowercased()
        step.directory = options["directory"]?.last.map { absolutePath($0, relativeTo: workingDirectory) }
        step.filters = options["filter"] ?? []
        step.filename = options["filename"]?.last
        step.mediaType = options["media-type"]?.last?.lowercased()
        step.path = options["path"]?.last.map { absolutePath($0, relativeTo: workingDirectory) }
        step.volume = try integer(options["volume"]?.last, name: "volume")
        step.plays = try integer(options["plays"]?.last, name: "plays")
        step.forever = flags.contains("forever")
        step.autoClose = try positiveDouble(options["auto-close"]?.last, name: "auto-close")
        step.width = try integer(options["width"]?.last, name: "width")
        step.height = try integer(options["height"]?.last, name: "height")
        step.entryType = options["entry-type"]?.last?.lowercased()
        step.defaultValue = options["default"]?.last
        step.required = flags.contains("required")
        step.maxLength = try integer(options["max-length"]?.last, name: "max-length")
        step.min = options["min"]?.last
        step.max = options["max"]?.last
        step.confirmLabel = options["confirm-label"]?.last
        step.cancelLabel = options["cancel-label"]?.last
        try validate(&step)
        return step
    }

    public static func validate(_ definition: InteractionDefinition) throws {
        guard !definition.steps.isEmpty, definition.steps.count <= maximumSteps else {
            throw StructuredError("INVALID_ARGUMENT", "an interaction must contain 1...\(maximumSteps) steps")
        }
        for var step in definition.steps { try validate(&step) }
        let data = try governorJSONEncoder().encode(definition)
        guard data.count <= maximumDefinitionBytes else {
            throw StructuredError("INVALID_ARGUMENT", "interaction definition exceeds 1 MiB")
        }
    }

    public static func validate(_ step: inout StepDefinition) throws {
        func nonempty(_ value: String?, _ option: String) throws {
            guard let value, !value.isEmpty else { throw StructuredError("INVALID_ARGUMENT", "--\(option) must be nonempty") }
        }
        if step.uiType != .media, step.width != nil || step.height != nil {
            throw StructuredError("INVALID_ARGUMENT", "--width and --height are valid only for image or video media")
        }
        switch step.uiType {
        case .display:
            try nonempty(step.message, "message")
            if step.buttons.count > 1 { throw StructuredError("INVALID_ARGUMENT", "display accepts one --button") }
        case .choice:
            try nonempty(step.message, "message")
            if step.buttons.isEmpty { step.buttons = ["Yes", "No"] }
            guard (2...maximumChoiceButtons).contains(step.buttons.count), step.buttons.allSatisfy({ !$0.isEmpty }) else {
                throw StructuredError("INVALID_ARGUMENT", "choice requires 2...\(maximumChoiceButtons) nonempty buttons")
            }
        case .file:
            if step.mode == "0" { step.mode = "open" }
            if step.mode == "1" { step.mode = "save" }
            guard step.mode == "open" || step.mode == "save" else { throw StructuredError("INVALID_ARGUMENT", "file requires --mode open or save") }
            if step.mode == "open", step.filename != nil { throw StructuredError("INVALID_ARGUMENT", "--filename is valid only for save mode") }
            if let filename = step.filename, (filename.isEmpty || URL(fileURLWithPath: filename).lastPathComponent != filename) {
                throw StructuredError("INVALID_ARGUMENT", "--filename must be a single nonempty filename")
            }
            if step.filters.isEmpty { step.filters = ["*"] }
            guard step.filters.allSatisfy({ !$0.isEmpty && !$0.contains("/") }) else { throw StructuredError("INVALID_ARGUMENT", "file filters must be nonempty filename globs") }
            if let directory = step.directory {
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: directory, isDirectory: &isDirectory), isDirectory.boolValue,
                      FileManager.default.isReadableFile(atPath: directory) else {
                    throw StructuredError("INVALID_ARGUMENT", "file picker directory is missing or unreadable")
                }
            }
        case .media:
            if step.mediaType == "0" { step.mediaType = "image" }
            if step.mediaType == "1" || step.mediaType == "sound" { step.mediaType = "audio" }
            if step.mediaType == "2" { step.mediaType = "video" }
            guard ["image", "audio", "video"].contains(step.mediaType ?? "") else { throw StructuredError("INVALID_ARGUMENT", "media requires --media-type image, audio, or video") }
            try nonempty(step.path, "path")
            if let volume = step.volume, !(0...100).contains(volume) { throw StructuredError("INVALID_ARGUMENT", "--volume must be 0...100") }
            if let plays = step.plays, plays <= 0 { throw StructuredError("INVALID_ARGUMENT", "--plays must be positive") }
            if step.plays != nil && step.forever { throw StructuredError("INVALID_ARGUMENT", "--plays and --forever are mutually exclusive") }
            if step.mediaType == "image" && (step.plays != nil || step.forever || step.volume != nil) { throw StructuredError("INVALID_ARGUMENT", "image media does not accept playback or volume options") }
            if let autoClose = step.autoClose, !autoClose.isFinite || autoClose <= 0 {
                throw StructuredError("INVALID_ARGUMENT", "--auto-close must be finite and positive")
            }
            if step.mediaType != "image" && step.autoClose != nil { throw StructuredError("INVALID_ARGUMENT", "--auto-close is valid only for images") }
            if let width = step.width, width <= 0 { throw StructuredError("INVALID_ARGUMENT", "--width must be positive") }
            if let height = step.height, height <= 0 { throw StructuredError("INVALID_ARGUMENT", "--height must be positive") }
            if step.mediaType == "audio", step.width != nil || step.height != nil {
                throw StructuredError("INVALID_ARGUMENT", "--width and --height are valid only for image or video media")
            }
        case .entry:
            if step.entryType == nil { step.entryType = "text" }
            if step.entryType == "0" { step.entryType = "number" }
            if step.entryType == "1" { step.entryType = "text" }
            if step.entryType == "2" { step.entryType = "multiline" }
            guard ["number", "text", "multiline"].contains(step.entryType ?? "") else { throw StructuredError("INVALID_ARGUMENT", "invalid --entry-type") }
            if let maxLength = step.maxLength, maxLength <= 0 { throw StructuredError("INVALID_ARGUMENT", "--max-length must be positive") }
            if step.entryType != "number", step.min != nil || step.max != nil { throw StructuredError("INVALID_ARGUMENT", "--min and --max require number entry") }
            if let min = step.min { _ = try normalizedDecimal(min) }
            if let max = step.max { _ = try normalizedDecimal(max) }
            if let min = step.min, let max = step.max, try compareDecimals(min, max) == .orderedDescending { throw StructuredError("INVALID_ARGUMENT", "--min must not exceed --max") }
            if let value = step.defaultValue { try validateEntry(value, step: step) }
        case .confirm:
            try nonempty(step.message, "message")
            if step.confirmLabel == "" || step.cancelLabel == "" { throw StructuredError("INVALID_ARGUMENT", "confirmation labels must be nonempty") }
        }
    }

    public static func validateEntry(_ value: String, step: StepDefinition) throws {
        let normalizedLines = value.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        if step.required && normalizedLines.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw StructuredError("INVALID_ARGUMENT", "a value is required")
        }
        if let limit = step.maxLength, normalizedLines.unicodeScalars.count > limit {
            throw StructuredError("INVALID_ARGUMENT", "value exceeds maximum length of \(limit) characters")
        }
        if step.entryType == "number" {
            _ = try normalizedDecimal(value)
            if let min = step.min, try compareDecimals(value, min) == .orderedAscending { throw StructuredError("INVALID_ARGUMENT", "number is below the minimum") }
            if let max = step.max, try compareDecimals(value, max) == .orderedDescending { throw StructuredError("INVALID_ARGUMENT", "number is above the maximum") }
        }
    }

    public static func normalizedDecimal(_ input: String) throws -> String {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let pattern = #"^[+-]?(?:[0-9]+(?:\.[0-9]*)?|\.[0-9]+)$"#
        guard trimmed.range(of: pattern, options: .regularExpression) != nil else { throw StructuredError("INVALID_ARGUMENT", "invalid decimal number") }
        var sign = ""
        var body = trimmed
        if body.hasPrefix("-") { sign = "-"; body.removeFirst() }
        else if body.hasPrefix("+") { body.removeFirst() }
        let pieces = body.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
        let significantWhole = pieces[0].drop(while: { $0 == "0" })
        let whole = significantWhole.isEmpty ? "0" : String(significantWhole)
        let fraction = pieces.count > 1
            ? String(pieces[1].reversed().drop(while: { $0 == "0" }).reversed()) : ""
        let zero = whole == "0" && fraction.isEmpty
        if zero { sign = "" }
        return sign + whole + (fraction.isEmpty ? "" : "." + fraction)
    }

    // Compare normalized decimal strings without Foundation Decimal's precision/exponent limits.
    public static func compareDecimals(_ lhs: String, _ rhs: String) throws -> ComparisonResult {
        let left = try normalizedDecimal(lhs)
        let right = try normalizedDecimal(rhs)
        if left == right { return .orderedSame }
        let leftNegative = left.hasPrefix("-")
        let rightNegative = right.hasPrefix("-")
        if leftNegative != rightNegative { return leftNegative ? .orderedAscending : .orderedDescending }
        let leftParts = (leftNegative ? String(left.dropFirst()) : left).split(separator: ".")
        let rightParts = (rightNegative ? String(right.dropFirst()) : right).split(separator: ".")
        let magnitude: ComparisonResult
        if leftParts[0].count != rightParts[0].count {
            magnitude = leftParts[0].count < rightParts[0].count ? .orderedAscending : .orderedDescending
        } else if leftParts[0] != rightParts[0] {
            magnitude = leftParts[0] < rightParts[0] ? .orderedAscending : .orderedDescending
        } else {
            let lf = leftParts.count > 1 ? String(leftParts[1]) : ""
            let rf = rightParts.count > 1 ? String(rightParts[1]) : ""
            let length = max(lf.count, rf.count)
            let lp = lf + String(repeating: "0", count: length - lf.count)
            let rp = rf + String(repeating: "0", count: length - rf.count)
            magnitude = lp < rp ? .orderedAscending : .orderedDescending
        }
        if !leftNegative { return magnitude }
        return magnitude == .orderedAscending ? .orderedDescending : .orderedAscending
    }

    public static func decimal(_ input: String) throws -> Decimal {
        let normalized = try normalizedDecimal(input)
        guard let result = Decimal(string: normalized, locale: Locale(identifier: "en_US_POSIX")) else { throw StructuredError("INVALID_ARGUMENT", "invalid decimal number") }
        return result
    }

    public static func lifetime(options: [String: [String]]) throws -> Int {
        let durationNames = ["days", "hours", "seconds"]
        let supplied = durationNames.contains { options[$0] != nil }
        if !supplied { return 30 * 86_400 }
        let days = try nonnegativeInteger(options["days"]?.last, name: "days") ?? 0
        let hours = try nonnegativeInteger(options["hours"]?.last, name: "hours") ?? 0
        let seconds = try nonnegativeInteger(options["seconds"]?.last, name: "seconds") ?? 0
        let (daySeconds, overflow1) = days.multipliedReportingOverflow(by: 86_400)
        let (hourSeconds, overflow2) = hours.multipliedReportingOverflow(by: 3_600)
        let (subtotal, overflow3) = daySeconds.addingReportingOverflow(hourSeconds)
        let (total, overflow4) = subtotal.addingReportingOverflow(seconds)
        guard !overflow1, !overflow2, !overflow3, !overflow4, total > 0 else { throw StructuredError("INVALID_ARGUMENT", "lifetime must have a positive, representable total") }
        return total
    }

    public static func extensionDuration(options: [String: [String]]) throws -> Int? {
        guard ["days", "hours", "seconds"].contains(where: { options[$0] != nil }) else { return nil }
        return try lifetime(options: options)
    }

    private static func integer(_ value: String?, name: String) throws -> Int? {
        guard let value else { return nil }
        guard let result = Int(value) else { throw StructuredError("INVALID_ARGUMENT", "--\(name) must be a whole number") }
        return result
    }

    private static func nonnegativeInteger(_ value: String?, name: String) throws -> Int? {
        guard let result = try integer(value, name: name) else { return nil }
        guard result >= 0 else { throw StructuredError("INVALID_ARGUMENT", "--\(name) must be nonnegative") }
        return result
    }

    private static func positiveDouble(_ value: String?, name: String) throws -> Double? {
        guard let value else { return nil }
        guard let result = Double(value), result.isFinite, result > 0 else { throw StructuredError("INVALID_ARGUMENT", "--\(name) must be positive") }
        return result
    }
}

public func filenameMatchesFilters(_ filename: String, filters: [String]) -> Bool {
    filters.isEmpty || filters.contains { pattern in
        pattern.withCString { fnmatch($0, filename, FNM_CASEFOLD) == 0 }
    }
}
