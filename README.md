# lmd

A single-binary LM Studio replacement for Apple Silicon.

`lmd` owns every part of the local-LLM workstation experience:

- **broker** on `localhost:5400` exposes an OpenAI-compatible HTTP API over any MLX model on disk
- **JIT model routing** spawns a dedicated [SwiftLM](https://github.com/SharpAI/SwiftLM) child per model, allocates ports from a pool, shuts them down under memory pressure
- **sensor sampling** to `memory.jsonl` for thermal, battery, and power time-series
- **fan control** is disabled in `lmd-serve` during the current moratorium; macOS owns fans while the broker runs
- **multi-tab TUI** (monitor, library, bench, events) rendered in raw terminal mode
- **benchmark orchestrator** for long-running model comparison jobs

One subsystem for unified logs (`io.goodkind.lmd`). One daemon
(`lmd-serve`). One interactive tool (`lmd-tui`).

## Install

```
make install
```

This:
1. Builds release binaries via SwiftPM (`swift build -c release`) and the MLX Metal shader library (`default.metallib`) via Tuist + xcodebuild. Both halves are required; see `Tools/lmd-dev.swift` for the rationale.
2. Copies the binaries and `mlx-swift_Cmlx.bundle` to `~/Library/Application Support/io.goodkind.lmd/bin/` (override with `PREFIX=/opt/...`).
3. Writes `~/Library/LaunchAgents/io.goodkind.lmd.serve.plist` from the template with your install path substituted in.
4. `launchctl bootstrap`s the agent into the current GUI session.

The broker starts running immediately and at every subsequent login. Requires Xcode (for `xcodebuild` + `tuist`) and a SwiftPM toolchain matching `Package.swift`'s `swift-tools-version`.

## Binaries

| Binary | Role | Lifecycle |
|---|---|---|
| `lmd` | Dispatcher. `lmd serve`, `lmd tui`, `lmd bench`, `lmd qa` execs the right sibling. | Short-lived (the user runs it). |
| `lmd-serve` | Broker + sensor sampler. Fan control is disabled during the current moratorium. | 24/7 LaunchAgent. |
| `lmd-tui` | Interactive dashboard (monitor / library / bench / events tabs). | Foreground while the user wants it open. |
| `lmd-bench` | Benchmark orchestrator. Long runs that survive terminal close. | Foreground or detached via `nohup`. |
| `lmd-qa` | TUI QA harness for CI (three drivers: tmux, pty, iTerm). | CI only. |

The broker on 5400 speaks the OpenAI API. Point Cursor, humanify, or
anything else at `http://localhost:5400` and it just works.

## Video

`POST /v1/chat/completions` may include OpenAI-style `video_url` content parts
for models whose catalog capabilities advertise `video: true`.

`lmd` stays dumb here on purpose. It validates that `video_url.url` points to a
local file and routes that file through to the MLX VLM backend. `lmd` does not
decode, retime, or expand the video itself. Temporal sampling is backend-owned.

With the current Swift Qwen video processors in upstream `mlx-swift-lm`, that
backend-owned policy is `2 FPS`, so video support is honest routing support, not
high-fidelity subtle-animation analysis.

## Environment

Every `lmd-serve` configuration key, its type, validity, and meaning live in [docs/configuration.md](docs/configuration.md). The values ship in `deploy/io.goodkind.lmd.serve.plist.example`. The broker fails fast at startup unless every key is defined, so edit the plist (or run `make install`) rather than relying on code defaults.

The client-side dispatcher also reads `LMD_HOST` and `LMD_PORT` for `lmd status`, `lmd load`, `lmd unload`, etc.

## Embeddings

`POST /v1/embeddings` accepts an OpenAI-shaped body (`model`, `input` as a string or array of strings, optional `encoding_format`, must not set `stream`).

Models are classified as `chat` or `embedding` when the catalog scans disk: `sentence_bert_config.json` or `modules.json`, `config.json` architectures (BERT family, Snowflake Arctic Embed, and similar), `model_type` hints, plus name patterns such as `embed` or `bge`. See `ModelCatalog.inferModelKind` in `SwiftLMRuntime`.

`GET /v1/models` and `GET /swiftlmd/loaded` include a `kind` field per entry (`chat` or `embedding`). Chat requests against an embedding id return HTTP 400.

Embedding inference uses backend families in process (`SwiftLMEmbed`, weights from the same directories as chat models). MLX-compatible embedder metadata routes to MLXEmbedders. NVIDIA Mistral bidirectional SentenceTransformers metadata, including models such as `nvidia/NV-EmbedCode-7b-v1`, routes to the native NVIDIA embedding backend.

Smoke test from the dispatcher: `lmd embed -h` then `lmd embed -m <id> -t "hello"`.

## Observability

Everything structured flows through `os.Logger` under subsystem `io.goodkind.lmd`:

```
# Live tail.
log stream --subsystem io.goodkind.lmd --info

# Last hour with category filter.
log show --predicate 'subsystem == "io.goodkind.lmd" AND category == "Broker"' --last 1h

# NDJSON for parsing.
log show --subsystem io.goodkind.lmd --last 30m --style ndjson
```

Data artifacts (`memory.jsonl`, bench `results/*.json`) live under `LMD_DATA_DIR` and are separate from logs. The Apple-native logging policy is codified in `AGENTS.md` §5, and `make lint` runs the shared formatting and static-analysis gates.

## Develop

SwiftPM pulls [macos-smc-fan](https://github.com/agoodkind/macos-smc-fan) from `https://github.com/agoodkind/macos-smc-fan.git` on branch `main`. A normal clone of this repo plus `tuist` on `PATH` (`brew install tuist`) is enough for `make build`.

```
make build              # hybrid SwiftPM (binaries) + xcodebuild (metallib)
make debug              # SwiftPM debug build only (no metallib refresh)
make test               # unit + snapshot + integration tests
make lint               # formatting and static-analysis gates
make tui-qa             # interactive TUI QA: tmux + pty + iTerm drivers
make run-tui            # launch the TUI in foreground
make run-serve          # run the broker in foreground (bypasses launchd)
make restart-serve      # pick up a new broker binary under launchd
make uninstall          # remove binaries + LaunchAgent
```

Every Make target is a thin alias over `Tools/lmd-dev.swift`. To skip Make and call it directly: `swift Tools/lmd-dev.swift help`.

## Layout

```
lmd/
  Package.swift          SwiftPM package (executables + library targets)
  Project.swift          Tuist Xcode project (used only to compile default.metallib)
  Tuist.swift            Tuist configuration shim
  Tuist/                 Tuist's own SwiftPM resolution for project generation
  Tools/
    lmd-dev.swift        Swift-script driver behind every Make target
  Sources/
    AppLogger/           shared os.Logger + swift-log bridge
    SwiftLMCore/         model descriptors, shared types
    SwiftLMBackend/      SwiftLM child-process lifecycle + MLX VLM video backend
    SwiftLMEmbed/        embedding backend families (MLXEmbedders + native NVIDIA)
    SwiftLMRuntime/      router, bench config + orchestrator, fan policy library, event bus
    SwiftLMMonitor/      macmon client, sensor sampler, battery reader
    SwiftLMControl/      XPC broker client + protocol
    SwiftLMTUI/          tab protocol, panels, ANSI + input parsers
    LMDServeSupport/     HTTP routing helpers shared between lmd-serve and tests
    lmd/                 dispatcher (lmd <subcommand>)
    lmd-serve/           broker + sampler daemon
    lmd-tui/             interactive dashboard
    lmd-bench/           benchmark runner
    lmd-qa/              three-driver TUI QA harness
  Tests/
    SwiftLMTUITests/     tab render snapshots
    SwiftLMRuntimeTests/ bench, router, fan logic, model catalog capabilities
    SwiftLMBackendTests/ SwiftLM server config, MLX VLM video backend
    SwiftLMCoreTests/    model capabilities
    SwiftLMControlTests/ broker protocol
    LMDServeTests/       video chat routing
    IntegrationTests/    binary launch + SIGINT, embeddings route
    Fixtures/            shared inputs (log categories, tuiqa coverage)
  deploy/
    io.goodkind.lmd.serve.plist.example   LaunchAgent template
    homebrew/                              brew formula
  plan/
    VIDEO_ROUTING_FINAL_DECISION.md        boundary for video request routing
```

## Related projects

- [SwiftLM](https://github.com/SharpAI/SwiftLM) upstream MLX inference engine; `lmd-serve` spawns one child per loaded model.
- [macos-smc-fan](https://github.com/agoodkind/macos-smc-fan) Swift package linked by the fan policy library. `lmd-serve` does not currently take over fans.
- [fancurveagent](https://github.com/agoodkind/macos-fan-curve) the LaunchAgent that owns fans independently of `lmd-serve` during the current moratorium.
