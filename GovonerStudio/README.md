# Govoner Studio

Govoner Studio is the native visual authoring companion for The Govoner. Drag interaction types from the palette into a top-to-bottom flow, reorder the cards, configure each step in the inspector, preview it with the existing Govoner runtime, and export reusable Bash functions.

Studio projects are JSON documents with the `.govonerstudio` extension. The editor also keeps a best-effort autosave of the last project under the user's Application Support directory.

## Bash export contract

Every export contains a guarded shared runtime followed by the project-specific function. The runtime declares one reusable set of Bash associative arrays:

- `GOVONER_RAN_LAST["$uuid"]`: `0` while pending, `1` after collection.
- `GOVONER_RAN_STATUS["$uuid"]`: `setup`, `live`, `post_run`, `gone`, or `error`.
- `GOVONER_RAN_RESULT_TYPE["$uuid"]`: the overall Govoner outcome.
- `GOVONER_RAN_RESULT_JSON["$uuid"]`: the complete, authoritative result document.
- `GOVONER_RAN_ERROR["$uuid"]`: an error message or JSON object when present.
- `GOVONER_RAN_RUN_NUMBER["$uuid"]`: the engine's run number.
- `GOVONER_RAN_STEP_RESULT_TYPE["$uuid:$step"]`: a step outcome.
- `GOVONER_RAN_STEP_VALUE["$uuid:$step"]`: the type-specific convenience value.
- `GOVONER_LAST_RUN_UUID`: the only non-array variable; it identifies the latest launch.

Call the generated interaction function directly so it can initialize globals in the current shell. Save `GOVONER_LAST_RUN_UUID` immediately if other launches may occur, then call `govoner_poll "$uuid"` to refresh without blocking or `govoner_wait "$uuid"` to wait and collect. The explicit refresh is necessary because Bash does not execute a callback merely because the separate Govoner service has finished.

UUID-keyed associative arrays require Bash 4 or newer. macOS's system `/bin/bash` 3.2 is intentionally rejected with a clear message.

## Build and run

From the repository root:

```bash
./script/build_and_run.sh
./script/build_and_run.sh --verify
```

The controlled `./build.sh` runs all tests and creates both the command-line Govoner archive and the signed `Govoner Studio.app` archive.
