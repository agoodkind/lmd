# lmd

A single-binary LM Studio replacement for Apple Silicon.

`lmd` owns every part of the local-LLM workstation experience:

- **broker** on `127.0.0.1:5400` exposes an OpenAI-compatible HTTP API over any MLX model on disk
- **JIT model routing** spawns a dedicated [SwiftLM](https://github.com/SharpAI/SwiftLM) child per model, allocates ports from a pool, shuts them down under memory pressure
- **sensor sampling** to `memory.jsonl` (was `swiftmon`) for historical thermal/battery/power data
- **fan control** via [`smcfan`](https://github.com/agoodkind/macos-smc-fan) scaled by in-flight request count so fans ramp up during inference and idle out quickly after
- **multi-tab TUI** (monitor, library, bench, events) rendered in raw terminal mode
- **benchmark orchestrator** for long-running model comparison jobs

One subsystem for unified logs (`io.goodkind.lmd`). One daemon
(`lmd-serve`). One interactive tool (`lmd-tui`).

## Install

```
make install
```

This:
1. Builds release binaries for all targets.
2. Copies them to `~/.local/bin/` (override with `PREFIX=/opt/...`).
3. Writes `~/Library/LaunchAgents/io.goodkind.lmd.serve.plist` from the template with your install path substituted in.
4. `launchctl bootstrap`s the agent into the current GUI session.

The broker starts running immediately and at every subsequent login.

## Binaries

| Binary | Role | Lifecycle |
|---|---|---|
| `lmd` | Dispatcher. `lmd serve`, `lmd tui`, `lmd bench`, `lmd qa` execs the right sibling. | Short-lived (the user runs it). |
| `lmd-serve` | Broker + sensor sampler + fan control. | 24/7 LaunchAgent. |
| `lmd-tui` | Interactive dashboard (monitor / library / bench / events tabs). | Foreground while the user wants it open. |
| `lmd-bench` | Benchmark orchestrator. Long runs that survive terminal close. | Foreground or detached via `nohup`. |
| `lmd-qa` | TUI QA harness for CI (three drivers: tmux, pty, iTerm). | CI only. |

The broker on 5400 speaks the OpenAI API. Point Cursor, humanify, or
anything else at `http://127.0.0.1:5400` and it just works.

## Environment

Defaults live in `deploy/io.goodkind.lmd.serve.plist.example`. All `lmd-serve` environment variables:

| Var | Default | Meaning |
|---|---|---|
| `LMD_HOST` | `127.0.0.1` | Broker bind host. |
| `LMD_PORT` | `5400` | Broker bind port. |
| `LMD_BUDGET_GB` | `80` | Max GB of models resident at once. Evictions happen above this. |
| `LMD_IDLE_MINUTES` | `15` | After this many minutes idle, unload a chat (SwiftLM) model. |
| `LMD_EMBEDDING_IDLE_MINUTES` | `60` | Idle timeout for in-process MLX embedding backends (often longer than chat). |
| `LMD_SAMPLE_INTERVAL` | `15` | Seconds between sensor samples. |
| `LMD_DATA_DIR` | `~/Library/Application Support/io.goodkind.lmd` | Where `memory.jsonl` lands. |
| `LMD_SMCFAN_BINARY` | `/Users/.../macos-smc-fan/Products/smcfan` | Path to the `smcfan` CLI. |
| `LMD_SWIFTLM_BINARY` | `~/Sites/SwiftLM/.build/arm64-apple-macosx/release/SwiftLM` | SwiftLM inference engine to spawn. |

The client-side dispatcher also reads `LMD_HOST` and `LMD_PORT` for `lmd status`, `lmd load`, `lmd unload`, etc.

## Embeddings

`POST /v1/embeddings` accepts an OpenAI-shaped body (`model`, `input` as a string or array of strings, optional `encoding_format`, must not set `stream`).

Models are classified as `chat` or `embedding` when the catalog scans disk: `sentence_bert_config.json` or `modules.json`, `config.json` architectures (BERT family, Snowflake Arctic Embed, and similar), `model_type` hints, plus name patterns such as `embed` or `bge`. See `ModelCatalog.inferModelKind` in `SwiftLMRuntime`.

`GET /v1/models` and `GET /swiftlmd/loaded` include a `kind` field per entry (`chat` or `embedding`). Chat requests against an embedding id return HTTP 400.

Embedding inference uses MLXEmbedders in process (`SwiftLMEmbed`, weights from the same directories as chat models). Example model id style: `Snowflake/snowflake-arctic-embed-l` when that layout exists under `~/.lmstudio/models`.

Smoke test from the dispatcher: `lmd embed -h` then `lmd embed -m <id> -t "hello"`.

## Observability

Everything structured flows through `os.Logger` under subsystem `io.goodkind.lmd`:

```
# Live tail.
log stream --subsystem io.goodkind.lmd --info

# Last hour with category filter.
log show --predicate 'subsystem == "io.goodkind.lmd" AND category == "FanCoordinator"' --last 1h

# NDJSON for parsing.
log show --subsystem io.goodkind.lmd --last 30m --style ndjson
```

Data artifacts (`memory.jsonl`, bench `results/*.json`) are separate from logs. See `plan/logging-migration.md`.

## Develop

```
make build              # release build of everything
make test               # unit + snapshot + integration tests
make tui-qa             # interactive TUI QA: tmux + pty + iTerm drivers
make log-audit          # enforce the Apple-native logging policy
make run-tui            # launch the TUI in foreground
make run-serve          # run the broker in foreground (bypasses launchd)
make restart-serve      # pick up a new broker binary under launchd
make uninstall          # remove binaries + LaunchAgent
```

## Layout

```
lmd/
  Sources/
    AppLogger/           shared os.Logger + swift-log bridge
    SwiftLMCore/         model descriptors, shared types
    SwiftLMBackend/      SwiftLM child-process lifecycle
    SwiftLMEmbed/        MLX embedding backends (MLXEmbedders)
    SwiftLMRuntime/      router, bench config + orchestrator, fan + event bus
    SwiftLMMonitor/      macmon client, sensor sampler, battery reader
    SwiftLMTUI/          tab protocol, panels, ANSI + input parsers
    lmd/                 dispatcher (lmd <subcommand>)
    lmd-serve/           broker + sampler + fan daemon
    lmd-tui/             interactive dashboard
    lmd-bench/           benchmark runner
    lmd-qa/              three-driver TUI QA harness
  Tests/
    SwiftLMTUITests/     tab render snapshots
    SwiftLMRuntimeTests/ bench, router, fan logic
    IntegrationTests/    binary launch + SIGINT
    Fixtures/            shared inputs (log categories, tuiqa coverage)
  deploy/
    io.goodkind.lmd.serve.plist.example   LaunchAgent template
    homebrew/                              brew formula
  plan/
    logging-migration.md                   Apple-native logging policy
    GENERALIZATION.md                      architecture roadmap
```

## Related projects

- [SwiftLM](https://github.com/SharpAI/SwiftLM) upstream MLX inference engine; `lmd-serve` spawns one child per loaded model.
- [macos-smc-fan](https://github.com/agoodkind/macos-smc-fan) smcfan CLI used by `FanCoordinator`.
- [fancurveagent](https://github.com/agoodkind/macos-fan-curve) the LaunchAgent that owns fans when `lmd-serve` is not running. `lmd-serve` boots it out on takeover and re-bootstraps it on release.
