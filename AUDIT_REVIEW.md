# Bug-fix review — 2026-09-16

Reviewed the Governor service, persistence and file protocol, IPC, renderer,
CLI/wrappers, Studio project/export/installation code, shell runtime, and build/test
entry points. The original 16 Swift tests passed before changes.

## Confirmed issues fixed

| Area | Failure and correction | Verification |
| --- | --- | --- |
| Renderer lifecycle | An old worker exit removed the new worker after rearm. Validate run/token before changing worker ownership. | Controlled old-exit regression; native rearm smoke |
| Renderer lifecycle | A UUID-wide intentional-stop flag could suppress a later run's crash. Removed it; persisted run identity determines whether an exit is stale. | Timeout/rearm/new-crash regression |
| Startup deadline | A delayed timeout callback could target a different run. Match the exact startup waiter. Also resolve pending waiters if a renderer completes without acknowledging presentation. | Lifecycle tests and review |
| Stacked failure | A crash between completion of one step and presentation of the next marked the next step skipped. Attribute failure to the next unfinished step. | Between-step crash regression |
| Completion delivery | A service exit after committing a result but before starting file publication left no retry marker. Persist pending delivery with the final result. | Restart/recovery regression |
| Atomic output | Missing output with a saved inode could never be recreated because replacement always required a swap. Use exclusive creation when missing, retaining protection against unrelated files. | Removed-file recreation and unrelated-file protection regressions |
| File I/O | Interrupted writes were treated as permanent errors; cleanup could overwrite rename errno. Retry EINTR and retain the original publication error. | Review; file regressions |
| IPC | A failed reply could cause a mutating request to be resent. Retry connection establishment only, never a request that may have committed. | Lost-reply regression |
| Process descriptors | Service/client sockets lacked close-on-exec. Set it on listening, connected, and accepted sockets. | Descriptor-flag regression and native smoke |
| Renderer launch | A failed process launch left its reader waiting on the parent's open pipe. Close unused pipe writers on failure. | Failure-path review; full build |
| SQLite reads | Row iteration treated SQLite errors as successful end-of-results, potentially returning incomplete state. Require SQLITE_DONE before returning records. | Query-path review; lifecycle/persistence tests |
| Child output | Wrappers and Studio waited for child exit before draining pipes, deadlocking on large output. Share a concurrent stdout/stderr capture implementation. | 256 KiB on each stream; actual wrapper with 256 KiB output |
| UUID lookup | Uppercase UUIDs passed validation but appeared absent in storage. Normalize requests before lookup. | Unit regression and native smoke |
| Decimal entry | Foundation Decimal rounded long bounds and rejected otherwise valid decimal strings outside its exponent range. Compare normalized strings exactly. Removed quadratic zero trimming. | Long-precision bounds, large magnitudes, 200,000 padding digits |
| Input validation | Nonfinite auto-close updates reached serialization; huge lifetimes produced unusable expiry dates; reset flags on unrelated CLI actions were ignored. Reject these inputs. | Validation/lifetime regressions and CLI smoke |
| File picker | Filename globs only disabled browser entries; typed save names could bypass them. Apply the same matcher in final panel validation. | Shared matcher tests; native delegate builds |
| Studio settings | Negative image close times and length limits silently disabled the setting. Reject invalid values while retaining zero as the documented off/unlimited value. | Studio numeric-setting regression |
| Studio arguments | Negative numbers and text beginning with a dash were emitted as separate arguments and rejected by the CLI. Use the equals form for those values. | Studio-to-CLI parser regression |
| One-shot options | Underscore startup-timeout aliases were sent to creation instead of triggering. Route canonical timeout names to the trigger. | Native wrapper smoke |
| Bash wait | A pending poll terminated scripts using `set -e`; zero-padded timeouts used octal arithmetic. Handle pending in a conditional and parse seconds in base ten. | Bash 5.2 runtime regressions |
| Bash rearm | Cached results were reused forever for a UUID, including subsequent runs. Check run number and reset completion state during setup/live. | Runtime rearm regressions, including no intermediate poll |
| Bash export | A runtime-source failure did not stop the exported script, and function names could collide with shell syntax/runtime helpers. Propagate source failure and reject conflicting names. | Export execution and name validation regressions |
| Managed scripts | Substring marker matching could discard script content; updates accumulated blank lines and mishandled missing final newline/CRLF. Recognize managed headers and complete delimiter lines, protect marker text in quoted values, and preserve the remaining body. | Content preservation, idempotence, CRLF, EOF, quote round-trip regressions |
| Installation | Relative paths became absolute before validation, uninstall skipped validation, and present components without versions were labeled missing. Validate original input for both operations and show unknown versions accurately. | Invalid-path tests, prefix/framework install/uninstall tests; status review |

## Validation

- Controlled macOS SwiftPM build/test with warnings treated as errors: **37 tests passed**.
- Bash **5.2.37** runtime tests: passed, including strict shell options, pending wait,
  timeout, rearm, source idempotence, and end. Bash was built in ignored `.build/`
  for this verification; no system installation was changed.
- Native renderer smoke: two-step SVG auto-close, rearm/run number 2, uppercase UUID,
  wrapper timeout alias, JSON results, and cleanup all passed.
- Actual one-shot wrapper drained a 256 KiB result without hanging.
- `git diff --check`: passed.
- Added the Bash runtime tests to CI; remote CI has not run for these local changes.

The optional native smoke is reproducible with `Tests/Integration/cli-smoke.py`.
The file-panel acceptance callback and administrator installation dialogs were not
operated interactively; their shared validation/install logic was tested. This is
a repository-wide bug-fix pass, not proof that no undiscovered defects remain.
