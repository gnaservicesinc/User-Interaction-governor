#!/usr/bin/env bash
# Run with Bash 4+: bash Tests/Runtime/runtime-tests.sh
set -euo pipefail
repo=$(cd "$(dirname "$0")/../.." && pwd)
fixture=$(mktemp -d)
trap 'rm -rf -- "$fixture"' EXIT
export GOVONER_TEST_STATE="$fixture"
export PATH="$fixture:$PATH"
cat >"$fixture/uig" <<'MOCK'
#!/bin/sh
case $1 in
  --status)
    mode=$(cat "$GOVONER_TEST_STATE/mode")
    if [ "$mode" = transition ]; then
      printf '2\n' >"$GOVONER_TEST_STATE/mode"
      printf '1\n'
    else printf '%s\n' "$mode"; fi
    ;;
  --dump) printf '{"run_number":%s}\n' "$(cat "$GOVONER_TEST_STATE/run")" ;;
  --get)
    while [ "$#" -gt 0 ]; do
      if [ "$1" = --field ]; then field=$2; break; fi
      shift
    done
    case $field in
      outcome) printf 'completed\n' ;;
      run_number) cat "$GOVONER_TEST_STATE/run" ;;
      error) printf 'null\n' ;;
      value) printf 'value-%s\n' "$(cat "$GOVONER_TEST_STATE/run")" ;;
      *) exit 7 ;;
    esac
    ;;
  --end) printf '3\n' >"$GOVONER_TEST_STATE/mode" ;;
  *) exit 2 ;;
esac
MOCK
chmod +x "$fixture/uig"
source "$repo/Components/govoner-runtime.sh"
uuid=regression-uuid
GOVONER_RAN_STEP_COUNT["$uuid"]=1
GOVONER_RAN_STEP_FIELD["$uuid:0"]=value
printf 'transition\n' >"$fixture/mode"
printf '1\n' >"$fixture/run"
# Called directly under errexit: pending is normal, not a fatal command failure.
govoner_wait "$uuid" 08
[[ ${GOVONER_RAN_LAST["$uuid"]} == 1 ]]
[[ ${GOVONER_RAN_STEP_VALUE["$uuid:0"]} == value-1 ]]
# A completed rearm must refresh even if nobody polled while setup/live.
printf '2\n' >"$fixture/run"
govoner_poll "$uuid"
[[ ${GOVONER_RAN_RUN_NUMBER["$uuid"]} == 2 ]]
[[ ${GOVONER_RAN_STEP_VALUE["$uuid:0"]} == value-2 ]]
printf '0\n' >"$fixture/mode"
if govoner_poll "$uuid"; then exit 1; else [[ $? == 1 ]]; fi
[[ ${GOVONER_RAN_LAST["$uuid"]} == 0 ]]
printf '1\n' >"$fixture/mode"
if govoner_wait "$uuid" 1; then exit 1; else [[ $? == 124 ]]; fi
[[ ${GOVONER_RAN_STATUS["$uuid"]} == live ]]
printf '2\n' >"$fixture/mode"
printf '3\n' >"$fixture/run"
govoner_wait "$uuid"
[[ ${GOVONER_RAN_STEP_VALUE["$uuid:0"]} == value-3 ]]
source "$repo/Components/govoner-runtime.sh"
[[ ${GOVONER_RAN_LAST["$uuid"]} == 1 ]]
govoner_end "$uuid"
govoner_poll "$uuid"
[[ ${GOVONER_RAN_STATUS["$uuid"]} == gone ]]
printf '%s\n' 'Bash runtime regressions passed.'
