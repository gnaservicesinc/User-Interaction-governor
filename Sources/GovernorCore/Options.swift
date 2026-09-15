import Foundation

public struct ParsedArguments: Sendable {
    public var action: GovernorAction?
    public var options: [String: [String]] = [:]
    public var flags: Set<String> = []
    public var resets: [String] = []
    public var help = false
    public var version = false

    public func values(_ name: String) -> [String] { options[name] ?? [] }
    public func value(_ name: String) -> String? { options[name]?.last }
    public func has(_ name: String) -> Bool { flags.contains(name) }
}

public enum ArgumentParser {
    private static let actions: [String: GovernorAction] = [
        "new": .new, "n": .new, "stack": .stack, "update": .update,
        "trigger": .trigger, "rearm": .rearm, "status": .status,
        "dump": .dump, "get": .get, "extend": .extend, "end": .end,
    ]

    private static let aliases: [String: String] = [
        "ui_type": "ui-type", "trigger_path": "trigger-path", "shown_path": "shown-path",
        "user_finished_path": "user-finished-path", "response_path": "response-path",
        "response_type": "response-path", "response_format": "response-format",
        "exit_path": "exit-path", "uuid_path": "uuid-path", "start_timeout": "start-timeout",
        "entry_type": "entry-type", "media_type": "media-type", "auto_close": "auto-close",
        "max_length": "max-length", "confirm_label": "confirm-label", "cancel_label": "cancel-label",
        "error_format": "error-format",
    ]

    private static let booleanOptions: Set<String> = ["wait", "required", "forever"]
    private static let repeatableOptions: Set<String> = ["button", "filter", "reset"]
    private static let valueOptions: Set<String> = [
        "uuid", "ui-type", "title", "message", "button", "trigger-path", "shown-path",
        "user-finished-path", "response-path", "response-format", "exit-path", "uuid-path",
        "days", "hours", "seconds", "start-timeout", "timeout", "format", "field", "step",
        "output", "reset", "mode", "directory", "filter", "filename", "media-type", "path",
        "volume", "plays", "auto-close", "entry-type", "default", "max-length", "min", "max",
        "confirm-label", "cancel-label", "error-format",
    ]

    public static func parse(_ arguments: [String]) throws -> ParsedArguments {
        var parsed = ParsedArguments()
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            if argument == "--help" || argument == "-h" { parsed.help = true; index += 1; continue }
            if argument == "--version" { parsed.version = true; index += 1; continue }
            guard argument.hasPrefix("-") else {
                throw StructuredError("INVALID_ARGUMENT", "unexpected positional argument: \(argument)")
            }
            let stripped = argument.hasPrefix("--") ? String(argument.dropFirst(2)) : String(argument.dropFirst())
            let pieces = stripped.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let rawName = String(pieces[0])
            let name = aliases[rawName] ?? rawName.replacingOccurrences(of: "_", with: "-")
            if let action = actions[name] {
                guard pieces.count == 1 else { throw StructuredError("INVALID_ARGUMENT", "action --\(name) takes no value") }
                guard parsed.action == nil else { throw StructuredError("INVALID_ARGUMENT", "exactly one action is allowed") }
                parsed.action = action
                index += 1
                continue
            }
            if booleanOptions.contains(name) {
                guard pieces.count == 1 else { throw StructuredError("INVALID_ARGUMENT", "--\(name) takes no value") }
                parsed.flags.insert(name)
                index += 1
                continue
            }
            guard valueOptions.contains(name) else { throw StructuredError("INVALID_ARGUMENT", "unknown option --\(name)") }
            let value: String
            if pieces.count == 2 {
                value = String(pieces[1])
            } else {
                guard index + 1 < arguments.count, !arguments[index + 1].hasPrefix("-") else {
                    throw StructuredError("INVALID_ARGUMENT", "--\(name) requires a value; use --\(name)=VALUE for values beginning with a dash")
                }
                index += 1
                value = arguments[index]
            }
            if name == "reset" {
                parsed.resets.append(canonicalOption(value))
            } else if repeatableOptions.contains(name) {
                parsed.options[name, default: []].append(value)
            } else {
                guard parsed.options[name] == nil else { throw StructuredError("INVALID_ARGUMENT", "--\(name) may be specified only once") }
                parsed.options[name] = [value]
            }
            index += 1
        }
        return parsed
    }

    public static func canonicalOption(_ value: String) -> String {
        let stripped = value.hasPrefix("--") ? String(value.dropFirst(2)) : value
        return (aliases[stripped] ?? stripped).replacingOccurrences(of: "_", with: "-")
    }
}

public let uigUsage = """
Usage: uig ACTION [OPTIONS]

Actions (exactly one):
  --new, -n   --stack   --update   --trigger   --rearm
  --status    --dump    --get      --extend    --end

Create a notice:
  id=$(uig --new --ui-type display --message "Backup complete.")
  uig --trigger --uuid "$id" --wait
  uig --end --uuid "$id"

Run 'uig --help' to show this text. See README.md for the complete contract.
"""
