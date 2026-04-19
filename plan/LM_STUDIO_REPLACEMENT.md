# LM Studio Replacement: Design & Build Plan

**Status:** draft
**Author:** Alex Goodkind <alex@goodkind.io>
**Started:** 2026-04-18
**Source repo:** `/Users/agoodkind/Sites/lm-review-stress-test/swiftbench`

## Goal

Turn the existing scaffolding (`SwiftLM`, `swiftbench`, `swiftmon`, `swifttop`) into a self-hosted replacement for LM Studio that runs on Apple Silicon, covers the core workflow (discover → load → serve → chat) via both an OpenAI-compatible HTTP API and a TUI control surface, and is structured so every concern lives in its own layer.

## Existing building blocks

| piece | what it already does | role in replacement |
|---|---|---|
| **SwiftLM** (`~/Sites/SwiftLM`) | MLX-based MLX inference engine. Full OpenAI-compatible HTTP. Supports chat/completions, thinking mode, VLM, ALM, SSD streaming, TurboQuant KV cache, speculative decoding. One model per process. | Inference engine. One instance per loaded model. |
| **swiftbench** | Test orchestrator that rotates through a fleet of models, spawning/killing SwiftLM per model, owning fan control, battery pause, memory eviction. | Source of lifecycle / eviction / fan logic. Will shrink once concerns move to libraries. |
| **swiftmon** | Standalone LaunchAgent. Persistent sensor daemon. Writes `memory.jsonl` continuously. Reuses existing macmon on port 8765. | Continues to own sampling + macmon lifecycle. |
| **swifttop** | TUI dashboard. Reads `memory.jsonl` + logs. Region-aware mouse scroll, live token stream, two-tier layout. | Evolves into the full control surface (dashboard + model manager + chat playground). |
| **macos-smc-fan** (`~/Sites/macos-smc-fan`) | Low-level SMC fan control. SwiftPM package. Reference style. | Vendor as a dependency (or git submodule) for fan control, instead of shelling out to `smcfan`. |

## Non-goals

- Cloud model support (OpenAI, Anthropic, etc.). This is local-only.
- Windows/Linux support.
- GUI app. The control surface is a TUI: same as `btop`, `lazygit`, `k9s`.

---

## Target architecture

One repo. One Swift package. Six libraries + four executables. No layer reaches across others.

```
swiftbench/
├   Package.swift            swift-tools-version: 6.0, StrictConcurrency on all targets
├   .swift-format            Apple's formatter config
├   .swiftlint.yml           SwiftLint rules (mirrors macos-smc-fan)
├   Makefile                 top-level targets: build, lint, format, test, install
├   plan/                    design docs (this file)
├   Sources/
│   ├   SwiftLMCore/         library: shared types & errors, no IO
│   │   ├   Models/
│   │   │   ├   ModelID.swift          (identifier: slug, path, huggingface id)
│   │   │   ├   ModelDescriptor.swift  (name, path, ctx_size, family, quant, size_bytes)
│   │   │   └   ModelCapabilities.swift (text, vision, audio, thinking)
│   │   ├   RequestEnvelope.swift      (normalized chat request DTO, Sendable)
│   │   ├   Errors.swift               (typed errors, no strings)
│   │   └   Logging+Categories.swift   (swift-log category helpers)
│   │
│   ├   SwiftLMBackend/      library: SwiftLM subprocess ownership, no orchestration
│   │   ├   SwiftLMServer.swift        (spawn, warmup, ready-poll, kill)
│   │   ├   ProcessHealth.swift        (isRunning, pid, stderr drain)
│   │   └   HTTPProxy.swift            (proxy incoming request → backend port)
│   │
│   ├   SwiftLMRuntime/      library: high-level decisions (the brain)
│   │   ├   ModelCatalog.swift         (scan ~/.lmstudio/models + HF cache)
│   │   ├   ModelRouter.swift          (map model_id → running SwiftLMServer; JIT spawn)
│   │   ├   MemoryBudget.swift         (how much RAM we have to spend)
│   │   ├   EvictionPolicy.swift       (LRU + capability weighting)
│   │   └   FanCoordinator.swift       (reads temps, drives macos-smc-fan)
│   │
│   ├   SwiftLMMonitor/      library: sensors (extracted from swiftmon)
│   │   ├   Sensors/
│   │   │   ├   VMStat.swift           (vm_stat wrapper)
│   │   │   ├   SwapUsage.swift        (vm.swapusage sysctl)
│   │   │   ├   MemoryPressure.swift   (memory_pressure wrapper)
│   │   │   ├   Battery.swift          (pmset wrapper)
│   │   │   └   MacmonClient.swift     (HTTP JSON fetch with timeout)
│   │   ├   MacmonLifecycle.swift      (spawn, reuse-on-port)
│   │   ├   Sample.swift               (wire format, Codable + Sendable)
│   │   └   SampleWriter.swift         (JSONL append)
│   │
│   ├   SwiftLMTUI/          library: reusable UX primitives (pure, no IO beyond stdout)
│   │   ├   Ansi/
│   │   │   ├   Escape.swift           (all CSI codes)
│   │   │   ├   Colors.swift           (theme palette)
│   │   │   └   Visible.swift          (width calc, pad, truncate)
│   │   ├   Layout/
│   │   │   ├   TwoTier.swift          (top row split + bottom pane)
│   │   │   ├   Row.swift              (label | value | extra)
│   │   │   └   ProgressBar.swift
│   │   ├   Panels/
│   │   │   ├   ThermalPanel.swift
│   │   │   ├   FansPanel.swift
│   │   │   ├   MemoryPanel.swift
│   │   │   ├   PowerPanel.swift
│   │   │   ├   BenchmarkPanel.swift
│   │   │   └   OutputStreamPanel.swift
│   │   ├   Input/
│   │   │   ├   KeyParser.swift        (arrows, j/k/g/G/space)
│   │   │   └   MouseParser.swift      (SGR 1006 events, region routing)
│   │   └   Screen.swift               (init/restore, alt buffer, SIGWINCH, atexit)
│   │
│   ├   swiftlmd/            EXECUTABLE: broker daemon (single OpenAI endpoint)
│   │   └   main.swift                  (wires SwiftLMRuntime + SwiftLMBackend into a HTTP server)
│   │
│   ├   swiftmon/            EXECUTABLE: sensor daemon (thin wrapper over SwiftLMMonitor)
│   │   └   main.swift
│   │
│   ├   swifttop/            EXECUTABLE: TUI (wraps SwiftLMTUI + talks to swiftlmd)
│   │   └   main.swift
│   │
│   └   swiftbench/          EXECUTABLE: the bench rig (unchanged behavior, now thinner)
│       └   main.swift
└   Tests/
    ├   SwiftLMCoreTests/
    ├   SwiftLMBackendTests/
    ├   SwiftLMRuntimeTests/            (fake Backend, validate eviction decisions)
    ├   SwiftLMMonitorTests/            (fake sensor readers, validate Sample schema)
    └   SwiftLMTUITests/                (snapshot tests of panel output strings)
```

### Dependency graph (one-way)

```
Core     used by every other target
Backend    Core
Runtime    Core, Backend, macos-smc-fan
Monitor    Core
TUI        Core  (NO Backend, NO Runtime: TUI talks to daemon over HTTP)
swiftlmd    Core, Backend, Runtime, Monitor
swiftmon    Core, Monitor
swifttop    Core, TUI
swiftbench    Core, Backend, Runtime, Monitor
```

**The TUI never loads a model itself.** It issues HTTP calls to `swiftlmd` and renders whatever comes back. That is the line separating UX from business logic.

---

## Style standards

Sourced from `macos-smc-fan`.

- **2-space indent** everywhere
- **File headers** with path + author + copyright
- **`// MARK: - Section`** dividers
- **DocC** `///` on every `public` symbol
- Explicit **`public` / `internal` / `private`** on every declaration
- **`Sendable`** on DTOs crossing task boundaries
- **`StrictConcurrency`** upcoming feature on every target
- **swift-log** categorized logger (`swiftlmd.router`, `swiftlmd.backend`, …)
- **Throwing functions** for failures. No `Optional<T>` as a stand-in for an error.
- **No shared mutable globals.** Each layer owns its state; pass dependencies in.

Tooling:

- **swift-format** (Apple, ships with Swift 6). Config at `.swift-format`.
- **SwiftLint**. Config at `.swiftlint.yml`. Rules mirror macos-smc-fan:
  - `discouraged_direct_init`
  - `explicit_acl`
  - `unused_import`
  - `force_cast: error`, `force_try: error`
- **Makefile targets:**
  - `make format`: swift-format in place
  - `make lint`: swift-format lint + swiftlint
  - `make test`: swift test
  - `make build`: release build of all binaries
  - `make install`: copies binaries + LaunchAgents to `~/.local/bin` and `~/Library/LaunchAgents`

---

## Concerns per layer

| layer | knows about | does **not** know about |
|---|---|---|
| **Core** | types, errors, logging | HTTP, terminals, processes |
| **Backend** | processes, ports, HTTP proxying | eviction policy, UX |
| **Runtime** | catalog, eviction, JIT, fans | terminal, HTTP request parsing |
| **Monitor** | sensors, JSONL schema | routing, UX |
| **TUI** | terminal escapes, panel layout, input parsing | model files, HTTP server, processes |
| **daemons** | wiring libraries together | domain details |

If a test file imports more than one of Core/Backend/Runtime/Monitor/TUI, that is a design smell.

---

## Phases

### Phase 0: prepare (no code changes)

Goal: agree on the structure. Write this doc. Ensure the bench run and humanify use case keep working on the current codebase during the refactor.

### Phase 1: library extraction (no behavior change)

Goal: move code into the library targets above. No new features. Every existing CLI invocation keeps working.

Steps:

1. Add `Package.swift` library targets, point them at empty `Sources/*/` directories.
2. Move code out of `swiftbench/main.swift` into the right library, one file at a time:
   - `FanController` → `SwiftLMRuntime/FanCoordinator.swift`
   - `SwiftLMServer` → `SwiftLMBackend/SwiftLMServer.swift`
   - `MemoryMonitor` → `SwiftLMMonitor/*`
3. Same for `swifttop`: panels + ansi helpers + mouse parser → `SwiftLMTUI`.
4. `swiftbench`, `swiftmon`, `swifttop` main.swift files shrink to a few hundred lines of wiring.
5. Add `.swift-format`, `.swiftlint.yml`, run `make format` across the tree.
6. Backfill tests per library (start with `SwiftLMRuntime` since it is the brain).

**Done when:** `make build && make test && make lint` green, all three current binaries behave identically, codebase passes swift-format.

### Phase 2: `swiftlmd` broker (first real feature)

Goal: one stable HTTP endpoint that clients (including humanify, clotilde, lm-review) can point at permanently. Models JIT-load on first request.

Surface:

```
GET  /health
GET  /v1/models                  list of on-disk + loaded models
POST /v1/chat/completions        model: <id> required; JIT spawn if not loaded
POST /v1/completions             same
GET  /metrics                    prometheus-compatible
GET  /swiftlmd/loaded            swiftlmd-specific: which models are currently loaded, on which ports
POST /swiftlmd/preload           warm a model without sending a request
POST /swiftlmd/unload            force-unload a model
GET  /swiftlmd/events            SSE stream of load/unload/eviction events (for TUI)
```

Behavior:

- First request for a not-yet-loaded model: spawn SwiftLM on a free port (starting at 5500). Block the request until ready. Subsequent requests reuse.
- If loading a new model would exceed the memory budget: evict the oldest idle model that is not currently mid-request.
- Idle timeout: 15 minutes. After that, unload.
- Concurrent requests to the same model: queue up to N in-flight slots (configurable, default 1).
- Fan and battery policies live in `FanCoordinator` and are shared with `swiftbench` so there is only one owner of fan state per session.

**Done when:** humanify runs against `http://127.0.0.1:5400/v1` and the first request triggers a model load; subsequent requests come back within ~100ms of compute time.

### Phase 3: swifttop control surface

Goal: make `swifttop` a full control panel, not just a passive monitor.

New modes (toggle with `Tab`):

1. **monitor**: current dashboard (thermal / fans / memory / power / bench progress).
2. **library**: list of models on disk; load / unload / set-default / show-details actions.
3. **chat**: pick a loaded model; send messages; stream tokens; scrollable transcript. No history persistence in v1.
4. **events**: live feed from `/swiftlmd/events`.

Implementation:

- Each mode is a `Screen` struct with `render(into: ScreenBuffer)`, `handle(_ input: InputEvent) -> ScreenAction`.
- Shared navigation chrome across modes: top bar with mode tabs, bottom bar with keybinds.
- TUI talks to `swiftlmd` via HTTP only. No direct filesystem reads.

**Done when:** you can load a model, hold a chat, and unload it without touching the CLI.

### Phase 4: model catalog & downloads

Goal: cover the "discover new model" flow that LM Studio handles.

- `POST /v1/models/pull` with HuggingFace ID. Broker shells out to `huggingface-cli download` (or native Swift via HF API).
- Progress via SSE.
- TUI library screen shows a `d` key: download dialog.
- Deletion: `DELETE /v1/models/<id>` removes from disk.

### Phase 5: capability expansion

- `/v1/embeddings` endpoint. Use a small embedding model loaded in parallel.
- Vision and audio modes surfaced as separate model entries (since SwiftLM needs different flags).
- Speculative decoding: expose `--draft-model` as a per-model config attribute.

### Phase 5a: JSON shunt (structured-output enforcement)

**Why this exists:** OpenAI's cloud API enforces `response_format: json_schema` at decode time via grammar-constrained sampling. Local MLX servers including SwiftLM accept the parameter to be OpenAI-compatible but silently ignore it: the decoder sees no constraint, so the model emits whatever its training tells it to. In practice: the model often writes prose instead of JSON, breaking every client that trusted the contract (humanify, clotilde, lm-review, any agent that expects structured output).

**Two-layer fix, implemented in order:**

**Layer 1: prompt-inject shunt (middleware, ships immediately).**
Lives in `SwiftLMRuntime/JSONShunt.swift`. Before the broker forwards a request to a backend, it inspects `response_format`:
- If `json_object` or `json_schema`, it rewrites the messages array:
  - Appends a hidden system message: *"You must respond with a single JSON value. No prose before or after. No markdown fences."*
  - If schema is present, serializes the schema as a compact string and appends: *"The JSON must conform to this schema: <schema>"*
- Post-response, it validates. If the content parses as JSON (after stripping think-blocks and fences), pass through. If not, retry once with a correction prompt that includes the invalid output and the original schema. Give up after one retry: return the best-effort result with an `x-swiftlmd-json-coerced: false` header for the client to decide.

This is what clotilde already does for the claude-cli path. We generalize the idea so every model behind the broker inherits it.

**Layer 2: grammar-constrained decoding (decoder, ships later).**
The real fix. Port `llguidance`-style or `outlines`-style constrained sampling into SwiftLM's decoder loop. Requires:
- Converting the JSON schema into a regex or token-level grammar.
- Masking logits each step so only schema-valid tokens have nonzero probability.
- Accepting `response_format` in SwiftLM's HTTP handler and threading it into the generation call.

Implementation candidates:
- **llguidance** (Microsoft, Rust): fastest option. Call via FFI.
- **outlines** (Python): Python-only, rules it out for our Swift-native path.
- **Hand-rolled regex mask** for the common `json_object` case: probably 300 lines of Swift, enough to cover 80% of humanify/clotilde/lm-review traffic without adding a C dependency.

Acceptance criteria:
- Given a test prompt that would naturally elicit prose (e.g. "Summarize this file"), request with `response_format: {type: json_object}`, and the response is valid JSON 100% of the time across 50 runs per model in the catalog.
- Given a `response_format: json_schema` with a nested schema, the response validates against the schema without post-hoc coercion.

**Why this is its own phase:** the prompt-inject shunt is a middleware change (one file in the broker), whereas grammar-constrained decoding touches SwiftLM's MLX inference loop. Different risk profiles, different review scope.

### Phase 6: polish & ops

- Homebrew formula: `brew install agoodkind/tap/swiftlmd`.
- LaunchAgent template for `swiftlmd` (always-on daemon).
- systemd-style unit tests in CI via GitHub Actions.

---

## Naming conventions

| external concept | internal symbol |
|---|---|
| OpenAI-compatible server | `SwiftLMServer` |
| one process instance | `SwiftLMInstance` |
| the broker daemon | `swiftlmd` |
| the TUI | `swifttop` |
| sensor daemon | `swiftmon` |
| the bench rig | `swiftbench` |
| the library package name | `SwiftLMKit` (if we decide to publish the libs as one product) |

Binaries stay lowercase. Library targets use `SwiftLM` prefix + `Core/Backend/Runtime/Monitor/TUI` suffix.

---

## Risks & unknowns

1. **SwiftLM spawn cost.** Loading a 30B model takes 15-60s. Clients issuing first-request must tolerate that or use `preload`.
2. **Metal shader lookup.** SwiftLM currently requires `WorkingDirectory` to be `.build/release` for `default.metallib` to be found. Either we keep that (LaunchAgent sets cwd) or we wrap SwiftLM to locate the shader bundle from its binary path.
3. **Single-port per model** means N loaded models = N processes. Easier to reason about than a single shared process but consumes more RAM overhead per model.
4. **Fan contention.** If both `swiftbench` and `swiftlmd` try to drive fans, one has to yield. `FanCoordinator` as a singleton-per-session (file lock?) avoids both writing simultaneously.
5. **MacOS permissions.** `macmon` needs root for some sensors. Already handled: user ran sudo once when installing. Document in README.

---

## Open questions

- Do we publish any of the libraries to GitHub as a standalone SwiftPM package?
- Do we want a `swiftctl` CLI for scripting (analogous to `kubectl`)?
- Should `swiftlmd` implement OpenAI's `organization` / `project` scoping so multiple tools can have isolated model access?
- Is there appetite for building a menu-bar app on top of `swiftlmd`, or is TUI enough?

---

## Immediate next actions (not scheduled yet)

- After the in-progress bench finishes: do the Phase 1 extraction in a single branch. Run the full test matrix again on the refactored binary to prove no regression.
- During extraction, keep the `swifttop` running against the bench so we dogfood the architecture boundary (TUI cannot reach into Runtime).

_End of plan._
