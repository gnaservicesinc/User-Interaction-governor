# User Interaction Governor

`uig` gives shell scripts and other local programs small, native macOS interactions without making their callers write GUI code. It supports notices, choices, file selection, images/audio/video, text or decimal entry, confirmations, sequential stacks, file-based signals, persistent results, rearming, expiry, and one-shot convenience commands.

Version 1 supports a local logged-in user on Apple-silicon macOS 13 or later. It deliberately does not provide remote display, cross-user prompting, browser UI, branching workflows, or embedded code execution.

## Quick start

Build, test, and create the controlled arm64 archives for The Govoner and Govoner Studio:

```bash
./build.sh
./install.sh
export PATH="$HOME/.local/bin:$PATH"
```

The command-line installer also installs the shared Bash runtime at `$HOME/.local/lib/ugl/govoner-runtime.sh`. Govoner Studio has a graphical **Manage UGL** screen for installing the complete component set into `/usr/local`, a custom prefix, or `/Library/Frameworks/UGL.framework`. The Framework layout exposes `Versions/Current/bin` for `PATH` and a stable `Versions/Current/Resources/govoner-runtime.sh` source path.

Create, show, inspect, and clean up a notice:

```bash
id=$(uig --new --ui-type display --message "Backup complete.")
uig --trigger --uuid "$id" --wait
uig --dump --uuid "$id"
uig --end --uuid "$id"
```

Or use a one-shot command:

```bash
ui-confirm "Replace the existing report?"
ui-file --mode open --filter "*.txt"
ui-media --media-type image --path ./preview.png
```

The one-shot commands perform create, trigger/wait, dump, and end with the same engine and result model. `ui-display` is silent on success by default; add `--json` to print its result.

## Govoner Studio

`Govoner Studio` is the native visual builder in [`GovonerStudio/`](GovonerStudio/). It turns the same sequential interaction model into a draggable flow: choose an interaction from the palette, drop or reorder cards on the canvas, edit type-specific settings in the inspector, preview through the existing engine, then copy or save the generated Bash functions.

Studio exports a small managed block containing a source line for the separately installed shared runtime plus the UI-specific launch function. Call the launch function directly, copy `GOVONER_LAST_RUN_UUID`, and use `govoner_poll "$uuid"` for a nonblocking refresh or `govoner_wait "$uuid"` to block until completion. Results are isolated in associative arrays keyed by UUID, including `GOVONER_RAN_LAST`, `GOVONER_RAN_RESULT_TYPE`, `GOVONER_RAN_RESULT_JSON`, and per-step values keyed as `"$uuid:$step"`. The generated comment block documents the exact fields for that flow.

**Update Existing Script…** opens a Bash script and owns only the region from its Bash `#!` line through `## End Managed By Govoner Studio Managed Area Do Not Remove`. On the first update, Studio inserts that region immediately after the existing shebang and preserves the rest of the file. Later updates replace the managed region so old functions and globals cannot accumulate. File permissions, including the executable bit, are preserved.

Bash cannot update a script's variables merely because the separate Govoner service completed, so polling is an explicit function call rather than a signal trap. UUID-keyed associative arrays also require Bash 4 or newer; macOS's built-in Bash 3.2 is rejected clearly by the generated runtime.

## Command model

Exactly one action is accepted:

```text
--new, -n    --stack      --update     --trigger
--rearm      --status     --dump       --get
--extend     --end
```

The normal lifecycle is `setup (0) -> live (1) -> post_run (2) -> gone (3)`. `--rearm` returns a completed interaction to setup without changing its UUID or expiry. An unknown well-formed UUID has status 3. User cancellation is result data, not a command failure.

Common creation options:

```text
--ui-type display|choice|file|media|entry|confirm
--title TEXT
--trigger-path PATH          --shown-path PATH
--user-finished-path PATH    --response-path PATH
--exit-path PATH             --uuid-path PATH
--days N --hours N --seconds N
```

The default lifetime is 30 days. Relative paths are resolved at creation. Custom protocol files must have distinct names under an existing local directory owned by the caller and inaccessible to group/other users. Pre-existing files and private governor state paths are rejected.

Canonical options use hyphens; underscore aliases from the original draft are accepted. Types are case-insensitive. Both `--option VALUE` and `--option=VALUE` work; use the equals form for a value beginning with a dash.

### Interaction types

- `display`: requires `--message`; optional `--button`.
- `choice`: requires `--message`; repeat `--button`. The default buttons are Yes and No.
- `file`: requires `--mode open|save`; supports `--directory`, repeated shell-style `--filter`, and save-only `--filename`.
- `media`: requires `--media-type image|audio|video` and `--path`; supports `--volume`, `--plays`, `--forever`, image-only `--auto-close`, and optional `--width`/`--height` window dimensions for images and videos. Oversized windows are fitted to the current screen. Audio does not accept window dimensions.
- `entry`: supports `--entry-type number|text|multiline`, `--message`, `--default`, `--required`, `--max-length`, and decimal `--min`/`--max`.
- `confirm`: requires `--message`; supports `--confirm-label` and `--cancel-label`.

Decimal entry is validated without binary floating-point conversion. For example, `+001.50` is returned as `1.5`, and `-0` as `0`. Text remains plain text and is never evaluated.

### Results

`--dump` returns the complete versioned JSON result. `--get --field NAME` selects a scalar; use `--format json` to preserve null or return structured errors. A stack requires `--step INDEX` for step fields, while a one-step result permits omitting it.

```bash
outcome=$(uig --get --uuid "$id" --field outcome)
value=$(uig --get --uuid "$id" --step 0 --field value)
uig --get --uuid "$id" --step 0 --field error --format json
uig --dump --uuid "$id" --output ./result.json
```

The complete response snapshot is committed before the finished marker is published. Removing the external snapshot does not remove the authoritative SQLite result, so `--get` and `--dump` continue to work.

### File signals

The service polls as well as observing command requests, so a missed filesystem notification does not lose a request:

```bash
private_dir=$(mktemp -d)
chmod 700 "$private_dir"
id=$(uig --new --ui-type choice --message "Start the job?" \
  --trigger-path "$private_dir/start" \
  --shown-path "$private_dir/shown.json" \
  --user-finished-path "$private_dir/finished.json" \
  --response-path "$private_dir/result.json" \
  --exit-path "$private_dir/end")
touch "$private_dir/start"
```

`trigger_path` is a request, `shown_path` acknowledges first presentation, `response_path` is a complete JSON snapshot, `user_finished_path` is published last, and `exit_path` requests cleanup. Markers contain the UUID, run number, and timestamp.

## Exit codes

| Code | Meaning |
| ---: | --- |
| 0 | Command succeeded, including user cancellation/dismissal |
| 2 | Invalid arguments or definition |
| 3 | Missing interaction (except status/end) |
| 4 | Invalid lifecycle state or busy interaction |
| 5 | Display, renderer, or media/backend failure |
| 6 | Storage, permission, path conflict, or delivery failure |
| 7 | Requested field unavailable or wrong format |
| 124 | Caller wait timed out; the interaction remains active |

Use `--error-format json` for a stable machine-readable error code, message, and retryable flag.

## Architecture and safety

- `uig` is the machine-readable client and wait implementation.
- `uigd` is an automatically started, single-instance per-user service. It serializes each interaction, owns SQLite state and expiry, reserves paths globally, scans file signals, and supervises renderers.
- `uig-renderer` is an isolated AppKit/AVKit worker for one frozen run. Every event carries the UUID, run number, and random worker token, so late events cannot mutate a later run.

The Unix socket lives in a mode-0700 user directory, is mode 0600, and verifies peer UID. SQLite uses WAL plus full synchronous commits. Output files use same-directory temporary files and exclusive/swap renames; replacement and deletion are checked against device/inode identity. Entered text, chosen paths, and response bodies are not logged.

The provisional limits are enforced: 100 steps, 32 choice buttons, 1 MiB of definition JSON, and 32 simultaneous renderer workers. Expired interactions and their results are removed rather than archived.

Media uses the native `NSImage` and AVFoundation decoders. Local desktop smoke verification covers SVG image presentation/auto-close and muted AIFF audio with two complete plays on the macOS 27 development host. Other local formats are accepted only when the native framework reports them as decodable; unsupported files finish with `UNSUPPORTED_MEDIA`. Network streams are not supported.

## Development

The package has no third-party dependencies. SQLite, AppKit, AVKit, and AVFoundation come from macOS. The build script runs SwiftPM with a sanitized environment and system-only `PATH`, then checks every packaged Mach-O for arm64 architecture, `/usr/local` dependencies, and valid ad-hoc signatures. `./build.sh` builds and tests optimized release binaries by default. Use `./build.sh --enable-debugging` only when you need unoptimized debug binaries; those use `-debug` package and archive names so they do not replace release artifacts.

The outputs are `dist/User-Interaction-Governor-macos-arm64.zip` and `dist/Govoner-Studio-macos-arm64.zip`. The Studio app bundles all nine executables and the shared Bash runtime. Preview uses the bundled `uig`, `uigd`, and renderer, while the management screen can copy the complete bundled set to an independent installation that keeps exported scripts working after the app is removed.

```bash
env -i HOME="$HOME" TMPDIR=/tmp PATH=/usr/bin:/bin:/usr/sbin:/sbin \
  DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  /usr/bin/xcrun swift test
```

Tests use a fake renderer for lifecycle behavior. Run `bash Tests/Runtime/runtime-tests.sh` with Bash 4 or newer to test the shared shell runtime. After a debug build, `python3 Tests/Integration/cli-smoke.py` runs an optional native renderer smoke on an active macOS desktop, briefly showing auto-closing image windows. It also checks rearming, wrapper arguments, large wrapper output, and cleanup with isolated temporary state. Pass a binary directory as its first argument to test another build. `Tests/Fixtures/smoke.svg` supplies the image fixture.

## License

GNU Affero General Public License v3.0. See [LICENSE](LICENSE).
