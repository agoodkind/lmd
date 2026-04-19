# AGENTS.md

Operating manual for any agent working in this repo. Optimized to stay correct as the code evolves: source-of-truth files own the lists, this file owns the rules.

---

## 1. What this repo is

`lmd` is a macOS-native LM Studio companion: an XPC broker (`lmd-serve`) registered as a per-user `LaunchAgent`, a CLI dispatcher (`lmd`), a TUI, a benchmark harness, and a TUI QA driver. All targets share a `Sources/AppLogger` module and a strict os.Logger discipline. Distribution is bare codesigned + notarized CLIs (no `.app`, no `.pkg` yet).

The project is Apple-platform only (`Package.swift` `platforms: [.macOS(...)]`) and uses Apple frameworks first: XPC for IPC, `os.Logger` for logging, `OSSignposter` for performance, `launchd` for service lifecycle, `notarytool` for distribution.

## 2. Sources of truth (do NOT duplicate these)

When something needs to change, edit the source of truth, not this file:

| Concern | Authoritative file |
|---|---|
| Targets, target dependencies, Swift language modes | `Package.swift` |
| Build / test / lint / install / sign / notarize commands | `Makefile` |
| Local-machine signing config (gitignored) | `config/signing.env` (template: `config/signing.env.example`) |
| LaunchAgent plist | `deploy/io.goodkind.lmd.serve.plist.example` |
| CI build/test pipeline | `.github/workflows/ci.yml` |
| CI release pipeline (sign + notarize + tag + release) | `.github/workflows/release.yml` |
| Local sign / notarize scripts | `scripts/sign-binaries.sh`, `scripts/notarize.sh`, `scripts/notary-setup.sh` |
| CI sign / notarize scripts | `scripts/ci-import-cert.sh`, `scripts/ci-sign.sh`, `scripts/ci-notarize.sh` |
| Active design notes | `plan/*.md` |
| User-facing overview | `README.md` |

If you find yourself enumerating targets, categories, or filenames in prose, stop and link to the source of truth instead.

## 3. Architecture invariants

- **One broker, many clients.** `lmd-serve` is a singleton `LaunchAgent` (`MachServices` entry `io.goodkind.lmd.control`); all other executables are short-lived clients that talk to it via `XPCSession` (see `Sources/SwiftLMControl/BrokerClient.swift`).
- **Clients close their session.** Every client must `client.close()` (which calls `session.cancel(reason:)`) before the process exits. Skipping this trips an `_xpc_api_misuse` SIGTRAP at deinit.
- **`XPCListener(service:)` only works under launchd.** `Sources/lmd-serve/XPCControl.swift` guards on `XPC_SERVICE_NAME` and throws a typed skip error when run outside launchd (tests, foreground `make run-serve`). Do not bypass that guard.
- **No file logging anywhere.** Every plist's `StandardOutPath` and `StandardErrorPath` is `/dev/null`. Operators read with `log stream --subsystem io.goodkind.lmd`.
- **Library targets are pure.** Long-lived state, sockets, file IO, and process spawning belong in `Sources/lmd-serve` (or its dedicated subsystems), never in a `library` target.

## 4. Build and toolchain

- Swift tools version is set in `Package.swift`. Match it locally (Xcode bundling that Swift release) and in CI runner choice.
- CI runs on the GitHub macOS runner whose Xcode matches our `swift-tools-version`. If you bump tools-version, also bump `runs-on` in both workflows in the same commit. Mismatches surface as `sending` / strict-concurrency errors that pass locally and fail on CI.
- `make build` = `swift build -c release`. `make debug` = unoptimized. `make test` runs the full suite.
- `make check`-style aggregate target does not exist; the CI workflow defines the canonical battery (build + test + log-audit + smoke).

## 5. Logging policy (NON-NEGOTIABLE)

This is the single most violated rule, so it lives here in full.

### 5.1 Initialization

Every executable's `main.swift` calls `AppLogger.bootstrap(subsystem: "io.goodkind.lmd")` as its first executable statement, before anything else. `bootstrap` is idempotent and never throws.

After `AppLogger.bootstrap`, every executable that depends on a swift-log-using package also calls `LoggingSystem.bootstrap` to install the `AppLogger` swift-log backend, so transitive `swift-log` events route to `os.Logger`.

### 5.2 Subsystem and category

- Subsystem is exactly `io.goodkind.lmd`. One subsystem for the whole repo. Do not invent per-target subsystems.
- Every source file declares exactly one logger:
  ```swift
  private let log = AppLogger.logger(category: "ModelRouter")
  ```
- Category is PascalCase, one-to-one with the file's logical type/module. No generic categories (`app`, `misc`, `default`).
- `Logger(subsystem:...)` is constructed only inside `Sources/AppLogger/`. Anywhere else is a violation caught by `make log-audit`.

### 5.3 Privacy annotations

Every interpolated value carries an explicit privacy annotation. Default-private is forbidden (renders `<private>` in release).

- `.public` for: model names, port numbers, file paths, durations, counts, enum values, error kinds, request IDs, event names.
- `.private` for: prompt text, model outputs, anything user-proprietary.
- `.private(mask: .hash)` for: stable correlation IDs derived from PII.

### 5.4 Levels

| API | Use for |
|---|---|
| `log.debug` | High-frequency inner-loop events; discarded by default in release. |
| `log.info` | Operational events worth remembering, not surfaced. |
| `log.notice` | Operator-visible events: request proxied, model loaded, bench cell completed. |
| `log.error` | Recoverable failures; process continues. |
| `log.fault` | Invariant violated; "should be impossible" path. |

Apple has no `.warn`. Do not gate calls behind `#if DEBUG`; use `sudo log config --subsystem io.goodkind.lmd --mode level:debug` at runtime instead.

### 5.5 Call site discipline

- Every `print`, `NSLog`, `debugPrint`, `dump`, `FileHandle.standardError.write` is replaced with the appropriate `log.<level>(...)` call. Sole exception: argv-CLI command output that the user explicitly asked for can write to `FileHandle.standardOutput`.
- Every state mutation gets a log event. Inner loops at `.debug`, transitions at `.info` / `.notice`.
- Event names are `<noun>.<verb>` dot notation: `model.loaded`, `router.request_accepted`, `xpc.session_closed`.
- Use structured interpolation, never pre-concatenated strings or `String(format:)`.

### 5.6 Signposts

Any code path that can exceed ~50ms wall time brackets itself with `OSSignposter` so Instruments and `xctrace record` can read it. Use a dedicated signposter for the `Performance` category. Do not measure-and-log with `CFAbsoluteTimeGetCurrent()` for things a signpost can express.

### 5.7 Verification

`make log-audit` greps Sources/ for forbidden patterns (`print(`, direct `Logger(subsystem:`, `import Logging` outside the bridge file). It must exit clean before any commit that touches Swift files.

## 6. Concurrency

`Package.swift` enables strict concurrency on every first-party target. Anything captured into a `Task.detached` or `@Sendable` closure must be `Sendable` or marked `nonisolated(unsafe)` with a justification comment. Older Swift point releases enforce this more strictly than newer ones, so a clean local build does not guarantee a clean CI build; rely on `.github/workflows/ci.yml` as ground truth.

## 7. Tests

- All tests live under `Tests/`, named `<TargetName>Tests` to match the convention `Package.swift` declares.
- Snapshot tests (TUI) regenerate goldens with `make snapshot-update`.
- Integration tests that need a live broker check `LMD_XPC_USE_LAUNCHD_DAEMON=1` and skip otherwise. Do not change tests to spawn `lmd-serve` themselves; that path traps inside `XPCListener`.
- The HTTP smoke test is a shell script, not an XCTest, and is invoked via `make smoke`.

## 8. Distribution

Two parallel pipelines, one identity, one team:

- **Local**: `make dist` runs `make build` -> `scripts/sign-binaries.sh` -> `scripts/notarize.sh`. Reads identity, team, bundle prefix, and notary keychain profile from `config/signing.env`. The keychain profile is created once with `make notary-setup`.
- **CI**: `.github/workflows/release.yml` runs on every push to `main`. It imports a single-identity `.p12` from secrets into a temp keychain, signs with `scripts/ci-sign.sh`, and notarizes with `scripts/ci-notarize.sh` using App Store Connect API key credentials (.p8 + key-id + issuer-id), then tags `YYYYMMDDHHmm-<hex-run>-<sha>` and creates a GitHub Release with the notarized zip attached.

Bare CLI binaries cannot be `stapler staple`d. First-launch Gatekeeper checks hit the network. Wrap into a `.pkg` if you need offline-friendly distribution; that's an open future task.

### 8.1 GitHub Actions secrets

The release pipeline requires these secrets on the repo. The names are referenced by the `env:` blocks in `.github/workflows/release.yml`:

| Secret | Source |
|---|---|
| `APPLE_DEVELOPER_ID_P12_BASE64` | base64 of single-identity Developer ID Application .p12 |
| `APPLE_DEVELOPER_ID_P12_PASSWORD` | import password for that .p12 |
| `APPLE_CODE_SIGN_IDENTITY` | SHA1 of the identity to use (disambiguates duplicates) |
| `APPLE_TEAM_ID` | 10-char team identifier |
| `APPLE_API_KEY_P8_BASE64` | base64 of `AuthKey_<keyid>.p8` from App Store Connect |
| `APPLE_API_KEY_ID` | 10-char key id |
| `APPLE_API_ISSUER_ID` | issuer UUID |

The .p12 must contain exactly one identity (full keychain exports run over the GitHub 48KB secret limit). Use `openssl pkcs12` with `-legacy` to extract a single identity.

## 9. Service lifecycle

- `make install` copies binaries into `~/.local/bin`, renders the LaunchAgent plist into `~/Library/LaunchAgents`, and bootstraps it under the GUI session.
- `make restart-serve` is the right command after a rebuild during development. It does `launchctl kickstart -k`, which picks up the new binary without a full bootout/bootstrap cycle.
- `make uninstall` reverses install in the correct order (bootout, then remove plist, then remove binaries).

## 10. Conventions for new code

- New executable target = new `.executableTarget` in `Package.swift` AND a corresponding entry in the `BINARIES` variable in `Makefile` AND the `DEFAULT_BINARIES` arrays in `scripts/sign-binaries.sh` and `scripts/notarize.sh` AND `scripts/ci-sign.sh` and `scripts/ci-notarize.sh`. These four lists must agree.
- New library target = new `.target` in `Package.swift` and (if it needs them) a `.testTarget`. No other ceremony.
- New file = `private let log = AppLogger.logger(category: "...")` at the top, before any other declarations.
- New plist under `deploy/` = `StandardOutPath` and `StandardErrorPath` both set to `/dev/null`.
- Cross-language scripts live as their own files with the appropriate extension (`.sh`, `.py`), invoked from Swift / Make / other shell. Don't inline scripts via heredoc.

## 11. Anti-patterns to reject on sight

- `Logger(subsystem: "io.goodkind.lmd", category: ...)` outside `Sources/AppLogger/`.
- `print` / `NSLog` / `debugPrint` anywhere in `Sources/` outside `Sources/AppLogger/`.
- A new subsystem string anywhere.
- A `.warn` log call (does not exist in Apple's API).
- File-based logging (`FileHandle` writing diagnostic output, `.log` file paths, plist `StandardOutPath` to a real path).
- `swift build` invocations that do not go through `make build` / `make debug` / the workflows. The Make targets are the contract.
- A cert SHA1 typed inline in a script. The Make target reads from `config/signing.env`; CI reads from secrets. Never both.
- An XPC client that does not call `close()` (or `defer { client.close() }`) before its enclosing scope exits.

## 12. When in doubt

1. Read `Package.swift` for the target graph.
2. Read `Makefile` for the canonical commands.
3. Read `.github/workflows/*.yml` for the canonical CI commands.
4. Read `plan/*.md` for the latest design intent on whatever subsystem you're touching.
5. Re-read this file and find the rule you were about to violate.
