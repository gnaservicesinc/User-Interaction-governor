import Foundation

public enum BashExporter {
    public static let defaultRuntimePath = "/usr/local/lib/ugl/govoner-runtime.sh"
    public static let managedStartMarker = "## Managed By Govoner Studio — changes in this area are replaced on export."
    public static let managedEndMarker = "## End Managed By Govoner Studio Managed Area Do Not Remove"

    public static func export(
        _ project: StudioProject,
        runtimePath: String = defaultRuntimePath
    ) throws -> String {
        try managedBlock(project, runtimePath: runtimePath) + "\n"
    }

    public static func updating(
        script: String,
        with project: StudioProject,
        runtimePath: String = defaultRuntimePath
    ) throws -> String {
        guard !script.isEmpty else { return try export(project, runtimePath: runtimePath) }
        guard script.hasPrefix("#!"),
              let firstLineEnd = script.firstIndex(where: { $0.isNewline }) else {
            throw StudioValidationError("The selected script must begin with a Bash #! line.")
        }
        let shebang = String(script[..<firstLineEnd])
        let interpreter = shebang.dropFirst(2).split(whereSeparator: { $0.isWhitespace }).map(String.init)
        let executable = interpreter.first.map { URL(fileURLWithPath: $0).lastPathComponent }
        let usesBash = executable == "bash" || (executable == "env" &&
            (interpreter.dropFirst().first == "bash" || Array(interpreter.dropFirst().prefix(2)) == ["-S", "bash"]))
        guard usesBash else {
            throw StudioValidationError("The selected script must use Bash in its #! line.")
        }

        let block = try managedBlock(project, runtimePath: runtimePath, shebang: shebang)
        let afterShebang = script.index(after: firstLineEnd)
        let body = String(script[afterShebang...])
        let remainder: String
        if body.hasPrefix(managedStartMarker + "\n") || body.hasPrefix(managedStartMarker + "\r\n") {
            // Match a complete marker line, including exports with CRLF or no final newline.
            var cursor = body.startIndex
            var end: String.Index?
            while cursor < body.endIndex {
                let newline = body[cursor...].firstIndex(where: { $0.isNewline }) ?? body.endIndex
                let line = body[cursor..<newline].trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
                if line == managedEndMarker {
                    end = newline < body.endIndex ? body.index(after: newline) : newline
                    break
                }
                if newline == body.endIndex { break }
                cursor = body.index(after: newline)
            }
            guard let end else {
                throw StudioValidationError("The managed area is missing its end marker; restore it before updating the script.")
            }
            remainder = String(body[end...])
        } else {
            remainder = body
        }
        return block + "\n" + remainder
    }

    private static func managedBlock(
        _ project: StudioProject,
        runtimePath: String,
        shebang: String = "#!/usr/bin/env bash"
    ) throws -> String {
        guard isShellIdentifier(project.functionName) else {
            throw StudioValidationError("Function names must start with a letter or underscore and contain only letters, numbers, and underscores.")
        }
        guard runtimePath.first == "/", !runtimePath.contains("\n"), !runtimePath.contains("\r"), !runtimePath.contains("\0") else {
            throw StudioValidationError("The Govoner Bash runtime must use an absolute path.")
        }
        _ = try project.validatedDefinitions()

        let commentName = project.name
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
        var output = shebang + "\n"
        output += managedStartMarker + "\n"
        output += "GOVONER_BASH_RUNTIME=\(shellQuote(runtimePath))\n"
        output += "if [[ ! -r $GOVONER_BASH_RUNTIME ]]; then\n"
        output += "  printf '%s\\n' \"Govoner Bash runtime not found: $GOVONER_BASH_RUNTIME\" >&2\n"
        output += "  return 2 2>/dev/null || exit 2\n"
        output += "fi\n"
        output += "# shellcheck source=/dev/null\n"
        output += "source \"$GOVONER_BASH_RUNTIME\" || { return 2 2>/dev/null || exit 2; }\n\n"
        output += functionComment(project: project, name: commentName)
        output += "\(project.functionName)() {\n"
        output += "  local uuid\n"
        output += "  GOVONER_LAST_RUN_UUID=\"\"\n"
        output += "  if ! uuid=$(\n"
        output += renderCommand(action: "--new", arguments: try project.steps[0].commandArguments(), indent: "    ")
        output += "\n"
        output += "  ); then\n"
        output += "    return 1\n"
        output += "  fi\n\n"
        output += "  GOVONER_LAST_RUN_UUID=\"$uuid\"\n"
        output += "  GOVONER_RAN_LAST[\"$uuid\"]=0\n"
        output += "  GOVONER_RAN_STATUS[\"$uuid\"]=setup\n"
        output += "  GOVONER_RAN_RESULT_TYPE[\"$uuid\"]=\"\"\n"
        output += "  GOVONER_RAN_RESULT_JSON[\"$uuid\"]=\"\"\n"
        output += "  GOVONER_RAN_ERROR[\"$uuid\"]=\"\"\n"
        output += "  GOVONER_RAN_RUN_NUMBER[\"$uuid\"]=0\n"
        output += "  GOVONER_RAN_STEP_COUNT[\"$uuid\"]=\(project.steps.count)\n"
        for (index, step) in project.steps.enumerated() {
            output += "  GOVONER_RAN_STEP_UI_TYPE[\"$uuid:\(index)\"]=\(shellQuote(step.uiType.rawValue))\n"
            output += "  GOVONER_RAN_STEP_FIELD[\"$uuid:\(index)\"]=\(shellQuote(step.primaryResultField ?? ""))\n"
            output += "  GOVONER_RAN_STEP_RESULT_TYPE[\"$uuid:\(index)\"]=\"\"\n"
            output += "  GOVONER_RAN_STEP_VALUE[\"$uuid:\(index)\"]=\"\"\n"
        }
        output += "\n"

        if project.steps.count > 1 {
            for (offset, step) in project.steps.dropFirst().enumerated() {
                let stepNumber = offset + 1
                output += "  if ! "
                output += renderCommand(
                    action: "--stack --uuid \"$uuid\"",
                    arguments: try step.commandArguments(),
                    indent: "    "
                ).droppingLeadingWhitespace()
                output += "; then\n"
                output += "    GOVONER_RAN_LAST[\"$uuid\"]=1\n"
                output += "    GOVONER_RAN_STATUS[\"$uuid\"]=error\n"
                output += "    GOVONER_RAN_RESULT_TYPE[\"$uuid\"]=launch_failed\n"
                output += "    GOVONER_RAN_ERROR[\"$uuid\"]=\(shellQuote("Could not add interaction \(stepNumber + 1)."))\n"
                output += "    command uig --end --uuid \"$uuid\" >/dev/null 2>&1 || true\n"
                output += "    return 1\n"
                output += "  fi\n\n"
            }
        }

        output += "  if ! command uig --trigger --uuid \"$uuid\"; then\n"
        output += "    GOVONER_RAN_ERROR[\"$uuid\"]=\"The Govoner could not present this interaction.\"\n"
        output += "    govoner_poll \"$uuid\" >/dev/null 2>&1 || true\n"
        output += "    return 1\n"
        output += "  fi\n"
        output += "  GOVONER_RAN_STATUS[\"$uuid\"]=live\n"
        output += "}\n"
        output += managedEndMarker
        return output
    }

    public static func shellQuote(_ value: String) -> String {
        let quoted = "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
        // Keep a marker embedded in user text from becoming a delimiter line.
        return quoted.replacingOccurrences(of: managedEndMarker,
            with: "## End Managed By ''Govoner Studio Managed Area Do Not Remove")
    }

    private static func isShellIdentifier(_ value: String) -> Bool {
        let reserved: Set<String> = ["if", "then", "else", "elif", "fi", "case", "esac", "for", "select", "while", "until", "do", "done", "in", "function", "time", "coproc", "govoner_poll", "govoner_wait", "govoner_end", "local", "command", "printf", "source", "return", "sleep"]
        guard !reserved.contains(value) else { return false }
        let bytes = Array(value.utf8)
        guard let first = bytes.first,
              first == 95 || (65...90).contains(first) || (97...122).contains(first) else { return false }
        return bytes.dropFirst().allSatisfy {
            $0 == 95 || (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0)
        }
    }

    private static func functionComment(project: StudioProject, name: String) -> String {
        var lines = [
            "# \(name)",
            "#",
            "# Call \(project.functionName) directly (not with command substitution), then copy",
            "# GOVONER_LAST_RUN_UUID if another launch may happen before you inspect this run:",
            "#   \(project.functionName)",
            "#   uuid=\"$GOVONER_LAST_RUN_UUID\"",
            "#",
            "# Completion is asynchronous. Run govoner_poll \"$uuid\" to refresh once, or",
            "# govoner_wait \"$uuid\" [timeout_seconds] to wait. govoner_poll returns 0 when",
            "# complete, 1 while pending, and 2 for an error. This UI populates:",
            "#   GOVONER_RAN_LAST[\"$uuid\"]             0 pending; 1 complete",
            "#   GOVONER_RAN_STATUS[\"$uuid\"]           setup, live, post_run, gone, or error",
            "#   GOVONER_RAN_RESULT_TYPE[\"$uuid\"]      overall outcome",
            "#   GOVONER_RAN_RESULT_JSON[\"$uuid\"]      complete lossless result JSON",
            "#   GOVONER_RAN_ERROR[\"$uuid\"]            error JSON/message, or empty",
            "#   GOVONER_RAN_RUN_NUMBER[\"$uuid\"]       The Govoner run number",
            "#   GOVONER_RAN_STEP_RESULT_TYPE[\"$uuid:N\"] outcome for step N",
            "#   GOVONER_RAN_STEP_VALUE[\"$uuid:N\"]     convenient primary value for step N",
            "# The JSON remains authoritative; command substitution trims trailing newlines from",
            "# the convenience values. Step keys use the form \"$uuid:N\".",
        ]
        for (index, step) in project.steps.enumerated() {
            let field = step.primaryResultField ?? "no scalar value (inspect its outcome or JSON)"
            lines.append("#   Step \(index): \(step.uiType.studioTitle) -> \(field)")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func renderCommand(
        action: String,
        arguments: [String],
        indent: String
    ) -> String {
        var lines = ["\(indent)command uig \(action)"]
        for argument in arguments {
            let rendered = shellQuote(argument)
            lines[lines.count - 1] += " \\"
            lines.append("\(indent)  \(rendered)")
        }
        return lines.joined(separator: "\n")
    }

}

private extension String {
    func droppingLeadingWhitespace() -> String {
        drop(while: { $0 == " " || $0 == "\t" }).description
    }
}
