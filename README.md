# lmd

- **broker** on `localhost:5400` exposes an OpenAI-compatible HTTP API over any MLX model on disk
- **JIT model routing** spawns a dedicated [SwiftLM](https://github.com/SharpAI/SwiftLM) child per model, allocates ports from a pool, shuts them down under memory pressure
- **sensor sampling** to `memory.jsonl` for thermal, battery, and power time-series
- **multi-tab TUI** (monitor, library, bench, events) rendered in raw terminal mode
- **benchmark orchestrator** for long-running model comparison jobs

TODO add pointer for other docs including logging and metrics
TODO add doc for the forks of mlx-* and SwiftLM and why (gemma, etc)
## Install

```
make install
```

TODO: document install script

The broker starts running immediately and at every subsequent login. 

| Binary | Role | Lifecycle |
|---|---|---|
| `lmd` | Dispatcher. `lmd serve`, `lmd tui`, `lmd bench`, `lmd qa` execs the right sibling. | Short-lived (the user runs it). |
| `lmd-serve` | Broker + sensor sampler. Fan control is disabled during the current moratorium. | 24/7 LaunchAgent. |
| `lmd-tui` | Interactive dashboard (monitor / library / bench / events tabs). | Foreground while the user wants it open. |
| `lmd-bench` | Benchmark orchestrator. Long runs that survive terminal close. | Foreground or detached via `nohup`. |
| `lmd-qa` | TUI QA harness for CI (three drivers: tmux, pty, iTerm). | CI only. |

To use and observe a running lmd from another tool or agent, see [docs/operations.md](docs/operations.md).

## Video

TODO; add doc about video 

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

lmd exposes two planes. For runtime state (loaded models, in-flight work, GPU memory, request spans), read the HTTP endpoints on `localhost:5400`: `/swiftlmd/loaded`, `/swiftlmd/metrics`, and `/swiftlmd/traces`. To use and observe a running lmd, see [docs/operations.md](docs/operations.md); for the field-by-field reference, see [docs/metrics.md](docs/metrics.md).

For a log narrative, everything structured flows through `os.Logger` under subsystem `io.goodkind.lmd`:

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

The chat backend, [SwiftLM](https://github.com/agoodkind/SwiftLM), is vendored as the `SwiftLM/` git submodule, so clone with `git clone --recurse-submodules` (or run `git submodule update --init --recursive` after a plain clone; `make build` also initializes it). `make build` builds SwiftLM's chat binary and its Metal library alongside lmd's own, so you no longer build or install SwiftLM separately. SwiftPM pulls [macos-smc-fan](https://github.com/agoodkind/macos-smc-fan) from `https://github.com/agoodkind/macos-smc-fan.git` on branch `main`. A clone of this repo plus `tuist` and `cmake` on `PATH` (`brew install tuist cmake`) is enough for `make build`.

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

## Related projects

- [macos-smc-fan](https://github.com/agoodkind/macos-smc-fan) Swift package linked by the fan policy library. `lmd-serve` does not currently take over fans.
- [Fan Curve](https://github.com/agoodkind/macos-fan-curve) the LaunchAgent that owns fans independently of `lmd-serve` during the current moratorium.
