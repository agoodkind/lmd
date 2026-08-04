# AGENTS.md

Operating manual for any agent working in this repo. Source-of-truth files own the lists. This file owns the rules.

---

## 1. What this repo is

`lmd` is a macOS-native LM Studio replacement. It ships an XPC broker (`lmd-serve`) registered as a per-user `LaunchAgent`, a CLI dispatcher (`lmd`), a TUI, a benchmark harness, and a TUI QA driver. Every target shares the `Sources/AppLogger` module and a strict os.Logger discipline. Distribution is bare codesigned and notarized CLIs, with no `.app` or `.pkg` yet.

The project targets Apple platforms only, declared by `platforms: [.macOS(...)]` in `Package.swift`. It uses Apple frameworks first: XPC for interprocess communication, `os.Logger` for logging, `OSSignposter` for performance, `launchd` for service lifecycle, and `notarytool` for distribution.

## 2. Sources of truth

Edit the source of truth, not this file.

| Concern | Authoritative file |
|---|---|
| SwiftPM targets, dependencies, Swift language modes | `Package.swift` |
| Tuist project (Xcode workspace, used only for `default.metallib`) | `Project.swift`, `Tuist.swift`, `Tuist/Package.swift` |
| Build, test, lint, install, sign, notarize implementation | `Tools/lmd-dev.swift` |
| Build, test, lint, install, sign, notarize entry points | `Makefile` (thin aliases over `Tools/lmd-dev.swift`) |
| Local-machine signing config (gitignored) | `config/signing.env` (template: `config/signing.env.example`) |
| Vendored SwiftLM chat backend | `SwiftLM/` git submodule (pinned by gitlink), built by `lmd-dev build-swiftlm` |
| LaunchAgent plist | `deploy/io.goodkind.lmd.serve.plist.example` |
| CI build and test pipeline | `.github/workflows/ci.yml` |
| CI release pipeline (sign, notarize, tag, release) | `.github/workflows/release.yml` |
| Active design notes | `plan/*.md` |
| User-facing overview | `README.md` |
| Using and observing a running lmd | `docs/operations.md` |
| M5 accelerator (NAX) kernels and the 16-bit miscompile workaround | `docs/nax.md` |
| Quantized embedding weights and how to put them in production | `docs/quantization.md` |

If you find yourself enumerating targets, categories, or filenames in prose, link to the source of truth instead.

## 3. Architecture invariants

- **One broker, many clients.** `lmd-serve` is a singleton LaunchAgent, registered under the `MachServices` entry `io.goodkind.lmd.control`. Every other executable is a short-lived client that reaches it over `XPCSession`. See `Sources/SwiftLMControl/BrokerClient.swift`.
- **Clients close their session.** Every client calls `client.close()` before its process exits, which calls `session.cancel(reason:)`. Skipping this trips an `_xpc_api_misuse` SIGTRAP at deinit.
- **`XPCListener(service:)` works only under launchd.** `Sources/lmd-serve/XPCControl.swift` guards on `XPC_SERVICE_NAME` and throws a typed skip error when the process runs outside launchd, such as in tests or a foreground `make run-serve`. Do not bypass that guard.
- **No file logging anywhere.** Every plist sets `StandardOutPath` to `/dev/null`, and operators read logs with `log stream --subsystem io.goodkind.lmd`. `StandardErrorPath` points at a real file under `~/Library/Logs/` so Swift runtime crash banners survive long enough to diagnose, because the os.Logger pipeline does not capture stderr. Those banners include `Fatal error:`, `Precondition failed:`, and native `SIGSEGV` from MLX or NIO.
- **Library targets are pure.** Long-lived state, sockets, file IO, and process spawning belong in `Sources/lmd-serve` or its dedicated subsystems, never in a `library` target.

### 3.1 Model-host processes and the chat exception

The broker is a pure router. It spawns one `lmd-model-host` process per loaded model and talks to it over a second XPC Mach service, `io.goodkind.lmd.host`, which is separate from the `io.goodkind.lmd.control` client surface. It forwards work, reads each child's real memory, and evicts by `SIGKILL`. The broker runs no model inference itself.

One resident model maps to exactly one process. Embedding and video honor that shape by loading their MLX model in-process inside the helper.

**Chat is the deliberate exception.** Its helper spawns the prebuilt SwiftLM binary and proxies the OpenAI request to it over loopback HTTP inside the helper. Chat is therefore two processes, the helper plus its SwiftLM child, and it reintroduces a loopback HTTP hop behind the XPC boundary. That runs against the one-process, no-internal-HTTP ideal.

Three reasons it diverges, so nobody folds it back into the broker without knowing the cost:

- The OpenAI chat response code lives only in SwiftLM's executable target, `Sources/SwiftLM/Server.swift`, and not in its importable `MLXInferenceCore` library. That code covers streaming SSE envelopes, `chatcmpl` ids, tool-call deltas, usage, and the reasoning split. The library exposes request decoders and token-level generation only. An in-process chat path cannot reuse that response code without forking SwiftLM and lifting `Server.swift` into a library product.
- SwiftLM churns hard. `Server.swift` changed about 74 times in the repo's first 80 days. A fork that restructures that file pays a recurring, conflict-prone merge cost on a hot file. Running the binary inherits upstream for free and stays byte-identical, because it is SwiftLM's own server.
- The trade is accepted deliberately. Chat keeps a second process and an internal loopback HTTP hop, and in exchange there is no SwiftLM fork to maintain and response fidelity is exact.

Revisit this only if SwiftLM ships its OpenAI serving as a library product. Chat can then collapse to a single in-process helper like embedding and video.

### 3.2 The vendored SwiftLM backend

lmd builds SwiftLM from the `SwiftLM/` submodule rather than fetching it separately.

`make build` runs the `generate` hook, `lmd-dev build-swiftlm`, which builds the chat binary and its metallib and stages both into `Products/Build/<config>/swiftlm/`. `make install` copies that into `<bin>/swiftlm/` and points `LMD_SWIFTLM_BINARY` there. Releases ship it in the same zip.

Before building, `build-swiftlm` checks out SwiftLM's `mlx-swift` and `mlx-swift-lm` submodules to lmd's resolved commits from `Package.resolved`. The chat binary therefore uses the same MLX as lmd's in-process embedding and video. A stamp at `Products/.swiftlm-built-sha`, keyed on the SwiftLM gitlink and those two MLX commits, skips the rebuild when nothing changed.

lmd does not modify the SwiftLM fork. It mirrors SwiftLM's CI build recipe.

Keep the submodule and its MLX submodules above the advisory fixes the osv audit enforces, because osv-scanner scans submodules. Bumping SwiftLM keeps its dependency pins patched. To bump it, run `cd SwiftLM && git checkout <ref>` then `git add SwiftLM`.

## 4. Build and toolchain

`Package.swift` sets the Swift tools version. Match it locally by using the Xcode that bundles that Swift release, and match it in the CI runner choice.

CI runs on the GitHub macOS runner whose Xcode matches our `swift-tools-version`. If you bump tools-version, bump `runs-on` in both workflows in the same commit. A mismatch surfaces as `sending` or strict-concurrency errors that pass locally and fail on CI.

`make build` runs a hybrid build, because neither builder alone produces a usable binary:

- SwiftPM (`swift build -c release`) links `swift-nio` with the resilient layout the Swift runtime expects, but cannot compile `.metal` shaders.
- Tuist with xcodebuild compiles `.metal` into `default.metallib` inside `mlx-swift_Cmlx.bundle`, but produces executables that crash on the first socket allocation. The crash is `swift_allocObject` with null `ManagedAtomic<Bool>` metadata; see vapor/vapor#3369.
- `Tools/lmd-dev.swift` orchestrates both, then stages the SwiftPM binaries and the Xcode-built bundle into `Products/Build/Release/`. `make install` reads only from that staging directory.

`make debug` runs the SwiftPM half only, producing unoptimized binaries with no metallib refresh. `make test` runs the full suite through Tuist. There is no aggregate `make check` target; the CI workflow defines the canonical battery of build, test, and smoke.

## 5. Logging policy

This is the most violated rule in the repo, so it lives here in full. It is not negotiable.

### 5.1 Initialization

Every executable's `main.swift` calls `AppLogger.bootstrap(subsystem: "io.goodkind.lmd")` as its first executable statement. `bootstrap` is idempotent and never throws.

After `AppLogger.bootstrap`, every executable that depends on a `swift-log` package also calls `LoggingSystem.bootstrap`. That installs the `AppLogger` backend, so transitive `swift-log` events route to `os.Logger`.

### 5.2 Subsystem and category

The subsystem is exactly `io.goodkind.lmd`, one for the whole repo. Do not invent per-target subsystems.

Every source file declares exactly one logger:

```swift
private let log = AppLogger.logger(category: "ModelRouter")
```

Category names are PascalCase and map one-to-one with the file's logical type or module. Generic categories such as `app`, `misc`, or `default` are not acceptable.

Construct `Logger(subsystem:...)` only inside `Sources/AppLogger/`. Constructing it anywhere else violates this policy.

### 5.3 Privacy annotations

Every interpolated value carries an explicit privacy annotation. Default-private is forbidden, because it renders as `<private>` in release.

- Use `.public` for model names, port numbers, file paths, durations, counts, enum values, error kinds, request IDs, and event names.
- Use `.private` for prompt text, model outputs, and anything user-proprietary.
- Use `.private(mask: .hash)` for stable correlation IDs derived from personal data.

### 5.4 Levels

| API | Use for |
|---|---|
| `log.debug` | High-frequency inner-loop events, discarded by default in release. |
| `log.info` | Operational events worth remembering, not surfaced. |
| `log.notice` | Operator-visible events: request proxied, model loaded, bench cell completed. |
| `log.error` | Recoverable failures where the process continues. |
| `log.fault` | A violated invariant, on a path that should be impossible. |

Apple provides no `.warn` level. Do not gate log calls behind `#if DEBUG`. Raise the level at runtime instead with `sudo log config --subsystem io.goodkind.lmd --mode level:debug`.

### 5.5 Call site discipline

Replace every `print`, `NSLog`, `debugPrint`, `dump`, and `FileHandle.standardError.write` with the matching `log.<level>(...)` call. The sole exception is CLI command output the user explicitly asked for, which may write to `FileHandle.standardOutput`.

Log every state mutation: inner loops at `.debug`, transitions at `.info` or `.notice`.

Name events in `<noun>.<verb>` dot notation, such as `model.loaded`, `router.request_accepted`, and `xpc.session_closed`.

Use structured interpolation. Never pre-concatenate strings or use `String(format:)`.

### 5.6 Signposts

Any code path that can exceed roughly 50ms of wall time brackets itself with `OSSignposter`, so Instruments and `xctrace record` can read it. Use a dedicated signposter for the `Performance` category. Do not measure and log with `CFAbsoluteTimeGetCurrent()` when a signpost expresses the same thing.

### 5.7 Verification

The lint gates check the owned Swift sources, meaning `Sources`, `Tests`, and `Tools/lmd-dev` as listed in `SWIFT_SOURCE_ROOTS`, against the repo's shared SwiftLint, format, dead-code, and swiftcheck rules. They must exit clean before any commit that touches Swift files.

## 6. Concurrency

`Package.swift` enables strict concurrency on every first-party target. Anything captured into a `Task.detached` or a `@Sendable` closure must be `Sendable`, or marked `nonisolated(unsafe)` with a comment justifying it.

Older Swift point releases enforce this more strictly than newer ones, so a clean local build does not guarantee a clean CI build. Treat `.github/workflows/ci.yml` as ground truth.

## 7. Tests

- Tests live under `Tests/`, named `<TargetName>Tests` to match the convention `Package.swift` declares.
- Snapshot tests for the TUI regenerate goldens with `make snapshot-update`.
- Integration tests that need a live broker check `LMD_XPC_USE_LAUNCHD_DAEMON=1` and skip otherwise. Do not change a test to spawn `lmd-serve` itself, because that path traps inside `XPCListener`.
- The HTTP smoke test lives in `Tools/lmd-dev.swift` as the `smoke` and `video-smoke` subcommands, invoked through `make smoke` and `make video-smoke`. There are no shell-script smoke runners.

## 8. Distribution

Two parallel pipelines share one identity and one team, and both run through `Tools/lmd-dev.swift`.

**Local.** `make dist` runs `make build`, then `lmd-dev sign`, then `lmd-dev notarize`. It reads identity, team, bundle prefix, and notary keychain profile from `config/signing.env`. Create the keychain profile once with `make notary-setup`.

**CI.** `.github/workflows/release.yml` runs on every push to `main` and supports manual dispatch. It imports a single-identity `.p12` from secrets into a temporary keychain with `lmd-dev ci-import-cert`, signs with `lmd-dev ci-sign`, and notarizes with `lmd-dev ci-notarize` using App Store Connect API key credentials. Main pushes publish stable releases with UTC calendar tags in `yy.m.d` form. If that day's base tag exists, the workflow appends the next `-rN` revision. Manual dispatch can instead select a prerelease, tagged `<yy.m.d>-pre.<YYYYMMDDHHmm>+<sha>`. Each release attaches the notarized zip.

Bare CLI binaries cannot be `stapler staple`d, so first-launch Gatekeeper checks reach the network. Wrapping into a `.pkg` would make distribution offline-friendly, and that remains an open task.

### 8.1 GitHub Actions secrets

The release pipeline requires these secrets on the repo. The `env:` blocks in `.github/workflows/release.yml` reference these names.

| Secret | Source |
|---|---|
| `APPLE_DEVELOPER_ID_P12_BASE64` | base64 of a single-identity Developer ID Application .p12 |
| `APPLE_DEVELOPER_ID_P12_PASSWORD` | import password for that .p12 |
| `APPLE_CODE_SIGN_IDENTITY` | SHA1 of the identity to use, which disambiguates duplicates |
| `APPLE_TEAM_ID` | 10-character team identifier |
| `APPLE_API_KEY_P8_BASE64` | base64 of `AuthKey_<keyid>.p8` from App Store Connect |
| `APPLE_API_KEY_ID` | 10-character key id |
| `APPLE_API_ISSUER_ID` | issuer UUID |

The .p12 must contain exactly one identity, because a full keychain export exceeds the GitHub 48KB secret limit. Extract a single identity using `openssl pkcs12` with `-legacy`.

## 9. Service lifecycle

- `make install` copies binaries into `~/Library/Application Support/io.goodkind.lmd/bin`, renders the LaunchAgent plist into `~/Library/LaunchAgents`, and bootstraps it under the GUI session.
- `make restart-serve` is the right command after a rebuild during development. It runs `launchctl kickstart -k`, which picks up the new binary without a full bootout and bootstrap cycle.
- `make uninstall` reverses install in the correct order: bootout, then remove the plist, then remove the binaries.

## 10. Conventions for new code

- A new executable target needs three entries that must agree: an `.executableTarget` in `Package.swift`, a `commandLineTarget` in `Project.swift`, and an entry in the `productBinaries` array in `Tools/lmd-dev.swift`.
- A new library target needs a `.target` in `Package.swift` and a `frameworkTarget` in `Project.swift`, plus a `.testTarget` in both when it needs tests. No other ceremony.
- A new file starts with `private let log = AppLogger.logger(category: "...")`, before any other declaration.
- A new plist under `deploy/` sets `StandardOutPath` to `/dev/null` and `StandardErrorPath` to a real file under `~/Library/Logs/`, so Swift runtime crash banners survive.
- Cross-language scripts live in their own files with the matching extension, such as `.sh` or `.py`, and are invoked from Swift, Make, or another shell. Do not inline a script through a heredoc. The lmd codebase itself targets pure Swift with no shell driver, per `plan/VIDEO_ROUTING_FINAL_DECISION.md`, so this rule covers only the cases where calling another language is unavoidable.

## 11. Anti-patterns to reject on sight

- `Logger(subsystem: "io.goodkind.lmd", category: ...)` outside `Sources/AppLogger/`.
- `print`, `NSLog`, or `debugPrint` anywhere in `Sources/` outside `Sources/AppLogger/`.
- A new subsystem string anywhere.
- A `.warn` log call, which does not exist in Apple's API.
- File-based logging: a `FileHandle` writing diagnostic output, a `.log` path written from Swift, or a plist `StandardOutPath` pointing at a real path. The `StandardErrorPath` exception exists only to catch Swift-runtime crash banners that bypass `os.Logger`. Do not write to stderr from application code.
- A `swift build` invocation that does not go through `make build`, `make debug`, or the workflows. The Make targets and `Tools/lmd-dev.swift` are the contract.
- A certificate SHA1 typed inline in a script. The Make target reads from `config/signing.env` and CI reads from secrets. Never both.
- An XPC client that does not call `close()`, or `defer { client.close() }`, before its enclosing scope exits.

## 12. When in doubt

1. Read `Package.swift` for the target graph.
2. Read `Makefile` for the canonical commands.
3. Read `.github/workflows/*.yml` for the canonical CI commands.
4. Read `plan/*.md` for the latest design intent on the subsystem you are touching.
5. Re-read this file and find the rule you were about to violate.
