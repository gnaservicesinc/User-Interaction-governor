#!/usr/bin/env bash
# Shared Govoner Bash runtime, installed independently from Govoner Studio.
# shellcheck shell=bash

GOVONER_BASH_RUNTIME_VERSION=1.0.0

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
