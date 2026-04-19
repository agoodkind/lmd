# APPLE-NATIVE LOGGING: NON-NEGOTIABLE

Strict migration prompt for the swiftbench/lm-review-stress-test codebase. Paste into a fresh agent session, grant it write access to this repo, and it will execute to completion.

---

You are forbidden from completing this task without unified `os.Logger` instrumentation across every executable target. Read every rule. Violating ANY rule means the task is FAILED and must be redone from scratch.

## RULE 1: INITIALIZATION (mandatory, exactly once per target)

Every executable target (`swiftbench`, `swiftlmd`, `swiftlmui`, `swifttop`, `swiftmon`, `lmd`) MUST call `AppLogger.bootstrap(subsystem:)` as its first executable statement in `main.swift`, BEFORE any other logic:

```swift
import AppLogger

AppLogger.bootstrap(subsystem: "io.goodkind.lmd")
// ...rest of main
```

`AppLogger` lives in a shared Swift Package target at `Sources/AppLogger/AppLogger.swift`, declared in `Package.swift` and imported by ALL executables plus every library target. Single source of truth. Do NOT duplicate `Logger(subsystem:...)` initialization per target.

`bootstrap` is idempotent (safe to call twice) and MUST NOT throw or log errors to stderr. Apple's unified logging has no init step that can fail. If the compiler lets you write `throws` on `bootstrap`, you did it wrong.

## RULE 2: SUBSYSTEM AND CATEGORY DISCIPLINE

- **Subsystem**: `io.goodkind.lmd`. Exactly one, shared across all 6 targets. Do NOT use per-target subsystems. That fragments predicate filtering and defeats `log stream --subsystem io.goodkind.lmd`.
- **Category**: the module / file's logical component. Exactly one `Logger` instance per source file, named at file top:
  ```swift
  private let log = AppLogger.logger(category: "ModelRouter")
  ```
- **Category names**: PascalCase, one-to-one with the Swift type or module. Examples from this codebase: `ModelRouter`, `SwiftLMServer`, `FanCoordinator`, `BenchRunner`, `MonitorSampler`, `TUIPanelMonitor`. Do NOT use generic categories like `app`, `misc`, `default`.
- **Helper API in `AppLogger`**:
  ```swift
  public static func logger(category: String) -> Logger
  ```
  Returns `Logger(subsystem: "io.goodkind.lmd", category: category)`. Do NOT construct `Logger(subsystem:...)` directly anywhere else in the codebase.

## RULE 3: PRIVACY ANNOTATIONS (mandatory, zero exceptions)

EVERY interpolated value in a log message MUST carry an explicit privacy annotation:

```swift
log.info("model.loaded name=\(modelName, privacy: .public) size_gb=\(sizeGB, privacy: .public)")
log.info("proxy.request peer=\(peer, privacy: .private(mask: .hash))")
```

- Default `.private` (Apple's default for unannotated values) is FORBIDDEN. It produces `<private>` in release builds and silently destroys debuggability.
- Use `.public` for: model names, port numbers, file paths, event names, durations, counts, enum values, error kinds, request IDs.
- Use `.private` for: user-entered prompt text, bench cell outputs, model responses, anything that could be a user's proprietary input.
- Use `.private(mask: .hash)` for: stable correlation of PII across events without exposing the value.

## RULE 4: LEVEL DISCIPLINE

Map events to `OSLogType` with these exact rules:

| Apple level | When to use |
|---|---|
| `.debug` | High-frequency inner-loop mutations: router in-flight ±1, EMA updates, sampled sensor values, per-token streaming updates. Discarded by default in release. |
| `.info` | Normal operational events: state transitions worth remembering but not surfaced. |
| `.default` (via `log.notice`) | Operator wants to see this during normal operation: request proxied, bench cell completed, model loaded. |
| `.error` | Recoverable failure: specific operation failed, process continues. |
| `.fault` | Invariant violated: reserved for "this should be impossible" paths. |

Apple has no `.warn`. Do NOT invent one.

Do NOT gate log calls behind `#if DEBUG`. `os.Logger` already discards `.debug` in release at the handler level. Enable at runtime with `sudo log config --subsystem io.goodkind.lmd --mode level:debug persist:default`.

## RULE 5: CALL SITES (strict scope: every state mutation)

- Every `print(...)`, `NSLog(...)`, `debugPrint(...)`, `dump(...)`, and `FileHandle.standardError.write(...)` MUST be replaced with the appropriate `log.<level>(...)` call, EXCEPT:
  - User-facing CLI output from `swiftbench` / `lmd` argv command results stays on stdout via `FileHandle.standardOutput.write(Data(...))`. Diagnostic output does NOT.
- Every function that mutates state MUST emit at least one log event describing the mutation. This is strict. Inner-loop mutations get `.debug`, notable transitions get `.info` / `.notice`. The event exists the moment someone needs it at debug time.
- Event names use `<noun>.<verb>` dot notation: `model.loaded`, `router.request_accepted`, `router.inflight_incremented`, `fan.state_changed`, `sample.captured`, `cell.completed`.
- Use structured interpolation, never pre-formatted strings:
  ```swift
  log.info("model.loaded name=\(modelName, privacy: .public) size_gb=\(sizeGB, privacy: .public)")
  ```
  FORBIDDEN:
  ```swift
  log.info("\(String(describing: model))")              // opaque dump
  log.info("model loaded: " + modelName)                // pre-concatenated
  log.info(String(format: "model %@ loaded", modelName)) // NSLog-era formatting
  ```

## RULE 6: SIGNPOSTS (mandatory for long operations)

Every code path that can exceed 50ms wall time MUST bracket itself with `OSSignposter`:

```swift
private let signposter = OSSignposter(subsystem: "io.goodkind.lmd", category: "Performance")

func loadModel(_ name: String) throws {
    let state = signposter.beginInterval("model.load", id: .exclusive, "name=\(name)")
    defer { signposter.endInterval("model.load", state) }
    // ...
}
```

Mandatory signpost coverage for this codebase: model spawn, HTTP proxy request, bench cell execution, fan state transition, memory sample capture.

Instruments and `xcrun xctrace record` read signposts natively; Console.app filters by category `Performance`. Do NOT use `CFAbsoluteTimeGetCurrent()` to time-and-log anything that should be a signpost.

## RULE 7: THIRD-PARTY LOGGING (swift-log bridge)

Hummingbird and other SPM deps use `swift-log` internally. Bridge swift-log to `os.Logger` so their output still lands in unified logging:

```swift
import Logging
import OSLog

LoggingSystem.bootstrap { label in
    AppLoggerSwiftLogBackend(category: label)
}
```

Where `AppLoggerSwiftLogBackend` is a `LogHandler` in `Sources/AppLogger/` that forwards every swift-log event to the matching `os.Logger`. swift-log labels become os.Logger categories verbatim.

Do NOT fork Hummingbird. Do NOT add a file backend to swift-log. Do NOT leave swift-log emitting to stdout.

## RULE 8: VERIFICATION

Add a Makefile target `log-audit` that greps every Swift source file and exits non-zero on any forbidden pattern:

```makefile
log-audit:
	@set -e; \
	echo "scanning for forbidden output calls..."; \
	! grep -rn -E '(^|[^a-zA-Z_])(print|NSLog|debugPrint|dump)\(' Sources/ \
	    --include='*.swift' \
	    --exclude-dir=AppLogger \
	  && echo "  output calls: OK"; \
	echo "scanning for direct Logger construction outside AppLogger..."; \
	! grep -rn 'Logger(subsystem:' Sources/ \
	    --include='*.swift' \
	    --exclude-dir=AppLogger \
	  && echo "  Logger construction: OK"; \
	echo "log-audit PASSED"
```

Run it. It MUST pass.

Additional runtime check. Capture `log stream` for 30s during a smoke flow touching every target, then assert:

- Subsystem `io.goodkind.lmd` produced at least one event from each of the 6 executables.
- Every category in `Tests/Fixtures/expected-categories.txt` appears at least once.
- No event has `<private>` in a field this rule set requires be `.public`.

## RULE 9: LAUNCHD PLIST HYGIENE

`deploy/com.goodkind.swiftlmd.plist.example` currently routes `StandardOutPath` / `StandardErrorPath` to files. Replace BOTH with `/dev/null`:

```xml
<key>StandardOutPath</key>
<string>/dev/null</string>
<key>StandardErrorPath</key>
<string>/dev/null</string>
```

Delete the corresponding `configs-battery/logs/swiftlmd.stdout.log` / `stderr.log` files and remove the `logs/` directory from any mkdir paths in the code. Operators read via `log stream --subsystem io.goodkind.lmd --info` exclusively.

Apply the same change to EVERY LaunchAgent / LaunchDaemon / XPCService plist in `deploy/`.

## RULE 10: NO SHORTCUTS

- Do NOT log to files. `os.Logger` owns persistence via the unified logging system. File mirroring is forbidden.
- Do NOT redirect stdout/stderr of any target to a log file.
- Do NOT use `Foundation.Logger`, `CocoaLumberjack`, `XCGLogger`, or any third-party logging package. Pure `import OSLog` + `os.Logger` only (plus the swift-log bridge for transitive deps).
- Do NOT construct `Logger` instances outside `AppLogger`.
- Do NOT gate logging behind `#if DEBUG`. Use `log config` at runtime.
- Do NOT invent custom privacy levels.
- Do NOT use `print` "just for this one test". Tests use `log.debug(...)` like production.
- The existing custom `class Logger` in `swiftmon/main.swift` and `swiftbench/main.swift` MUST be deleted. Rename any shadowing occurrences before migration.

## RULE 11: DATA ARTIFACTS ARE NOT LOGS

The following files are DATA ARTIFACTS (user-owned state), not logs, and are NOT subject to this policy:

- `configs-battery/memory.jsonl` is a deliberate sampled trace consumed by `analyze-configs.py`. Keep as-is.
- `configs-battery/results/<model>/<test>.json` holds bench result records. Keep as-is.
- `REPORT.md` is a generated bench summary. Keep as-is.

Do NOT route these through `os.Logger`. Do NOT rename. Do NOT delete. A separate "Apple Data Artifacts" policy governs them.

## DELIVERABLE CHECKLIST

- [ ] `Sources/AppLogger/AppLogger.swift` exists with `bootstrap(subsystem:)` and `logger(category:)`
- [ ] `Sources/AppLogger/SwiftLogBridge.swift` bridges swift-log to os.Logger
- [ ] All 6 target `main.swift` files call `AppLogger.bootstrap(subsystem: "io.goodkind.lmd")` first
- [ ] `LoggingSystem.bootstrap` is called after `AppLogger.bootstrap` in every target
- [ ] Every source file declares exactly one `private let log = AppLogger.logger(category: ...)`
- [ ] `Logger(subsystem:` does NOT appear outside `AppLogger.swift`
- [ ] Every interpolated value has an explicit `privacy:` annotation
- [ ] `print`, `NSLog`, `debugPrint`, `dump`, `FileHandle.standardError.write` removed everywhere except user-CLI stdout paths
- [ ] Existing custom `class Logger` in swiftmon and swiftbench is deleted
- [ ] Every state-mutating function emits at least one `log.<level>(...)` event with `<noun>.<verb>` name
- [ ] Model spawn, proxy request, bench cell, fan transition, memory sample all wrapped in `OSSignposter`
- [ ] All plists under `deploy/` route Standard{Out,Error}Path to `/dev/null`
- [ ] `make log-audit` passes with zero violations
- [ ] `log stream --subsystem io.goodkind.lmd --info` shows events from all 6 targets during a smoke pass
- [ ] `Tests/Fixtures/expected-categories.txt` exists and lists every category the smoke pass produces
- [ ] `memory.jsonl`, bench `results/*.json`, `REPORT.md` remain untouched

Failing any checkbox = task incomplete. Redo.
