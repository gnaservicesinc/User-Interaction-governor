import Foundation

public enum BashExporter {
    public static func export(_ project: StudioProject) throws -> String {
        guard isShellIdentifier(project.functionName) else {
            throw StudioValidationError("Function names must start with a letter or underscore and contain only letters, numbers, and underscores.")
        }
        _ = try project.validatedDefinitions()

        let commentName = project.name
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
        var output = sharedRuntime
        output += "\n"
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
        return output
    }

    public static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }

    private static func isShellIdentifier(_ value: String) -> Bool {
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

    private static let sharedRuntime = #"""
# Shared Govoner Bash runtime. Paste it once; additional Studio exports reuse it.
# UUID-keyed globals require Bash 4 or newer (macOS /bin/bash 3.2 is too old).
if (( ${BASH_VERSINFO[0]:-0} < 4 )); then
  printf '%s\n' 'Govoner exports require Bash 4 or newer for UUID-keyed associative arrays.' >&2
  return 2 2>/dev/null || exit 2
fi

if [[ -z ${GOVONER_BASH_RUNTIME_LOADED:-} ]]; then
  GOVONER_BASH_RUNTIME_LOADED=1
  declare -A GOVONER_RAN_LAST
  declare -A GOVONER_RAN_STATUS
  declare -A GOVONER_RAN_RESULT_TYPE
  declare -A GOVONER_RAN_RESULT_JSON
  declare -A GOVONER_RAN_ERROR
  declare -A GOVONER_RAN_RUN_NUMBER
  declare -A GOVONER_RAN_STEP_COUNT
  declare -A GOVONER_RAN_STEP_UI_TYPE
  declare -A GOVONER_RAN_STEP_FIELD
  declare -A GOVONER_RAN_STEP_RESULT_TYPE
  declare -A GOVONER_RAN_STEP_VALUE
  GOVONER_LAST_RUN_UUID=''

  govoner_poll() {
    local uuid=${1:-}
    local state payload outcome run_number error_json count index key field step_outcome value
    if [[ -z $uuid ]]; then
      printf '%s\n' 'govoner_poll: a UUID is required' >&2
      return 2
    fi
    if ! state=$(command uig --status --uuid "$uuid" 2>&1); then
      GOVONER_RAN_STATUS["$uuid"]=error
      GOVONER_RAN_ERROR["$uuid"]=$state
      return 2
    fi
    case $state in
      0)
        GOVONER_RAN_STATUS["$uuid"]=setup
        return 1
        ;;
      1)
        GOVONER_RAN_STATUS["$uuid"]=live
        return 1
        ;;
      2)
        GOVONER_RAN_STATUS["$uuid"]=post_run
        if [[ ${GOVONER_RAN_LAST["$uuid"]:-0} == 1 ]]; then
          return 0
        fi
        if ! payload=$(command uig --dump --uuid "$uuid" 2>&1); then
          GOVONER_RAN_STATUS["$uuid"]=error
          GOVONER_RAN_ERROR["$uuid"]=$payload
          return 2
        fi
        GOVONER_RAN_RESULT_JSON["$uuid"]=$payload
        outcome=$(command uig --get --uuid "$uuid" --field outcome 2>/dev/null) || outcome=unknown
        run_number=$(command uig --get --uuid "$uuid" --field run_number 2>/dev/null) || run_number=0
        error_json=$(command uig --get --uuid "$uuid" --field error --format json 2>/dev/null) || error_json=null
        GOVONER_RAN_RESULT_TYPE["$uuid"]=$outcome
        GOVONER_RAN_RUN_NUMBER["$uuid"]=$run_number
        [[ $error_json == null ]] && error_json=''
        GOVONER_RAN_ERROR["$uuid"]=$error_json
        count=${GOVONER_RAN_STEP_COUNT["$uuid"]:-0}
        for ((index = 0; index < count; index++)); do
          key="$uuid:$index"
          step_outcome=$(command uig --get --uuid "$uuid" --step "$index" --field outcome 2>/dev/null) || step_outcome=unknown
          GOVONER_RAN_STEP_RESULT_TYPE["$key"]=$step_outcome
          field=${GOVONER_RAN_STEP_FIELD["$key"]:-}
          value=''
          if [[ -n $field ]]; then
            value=$(command uig --get --uuid "$uuid" --step "$index" --field "$field" 2>/dev/null) || value=''
          fi
          GOVONER_RAN_STEP_VALUE["$key"]=$value
        done
        GOVONER_RAN_LAST["$uuid"]=1
        return 0
        ;;
      3)
        GOVONER_RAN_STATUS["$uuid"]=gone
        if [[ ${GOVONER_RAN_LAST["$uuid"]:-0} == 1 ]]; then
          return 0
        fi
        GOVONER_RAN_ERROR["$uuid"]='The interaction no longer exists.'
        return 2
        ;;
      *)
        GOVONER_RAN_STATUS["$uuid"]=error
        GOVONER_RAN_ERROR["$uuid"]="Unexpected status: $state"
        return 2
        ;;
    esac
  }

  govoner_wait() {
    local uuid=${1:-}
    local timeout=${2:-0}
    local deadline=0 result
    if ! [[ $timeout =~ ^[0-9]+$ ]]; then
      printf '%s\n' 'govoner_wait: timeout must be a whole number of seconds' >&2
      return 2
    fi
    if (( timeout > 0 )); then
      deadline=$((SECONDS + timeout))
    fi
    while :; do
      govoner_poll "$uuid"
      result=$?
      if (( result == 0 )); then return 0; fi
      if (( result != 1 )); then return "$result"; fi
      if (( deadline > 0 && SECONDS >= deadline )); then
        GOVONER_RAN_ERROR["$uuid"]='Timed out while waiting; the interaction is still active.'
        return 124
      fi
      sleep 0.1
    done
  }

  govoner_end() {
    local uuid=${1:-}
    [[ -n $uuid ]] || { printf '%s\n' 'govoner_end: a UUID is required' >&2; return 2; }
    command uig --end --uuid "$uuid" || return
    GOVONER_RAN_STATUS["$uuid"]=gone
  }
fi
"""#
}

private extension String {
    func droppingLeadingWhitespace() -> String {
        drop(while: { $0 == " " || $0 == "\t" }).description
    }
}
