# swiftlmd runbook

Operational notes for the broker daemon.

## What is it

A single HTTP endpoint that sits in front of every SwiftLM instance. Clients
(humanify, clotilde, lm-review, Cursor, etc.) point at `localhost:5400/v1` and
use any model by id. The broker spawns SwiftLM backends on demand, evicts
idle ones when memory runs out, and enforces JSON output for structured
requests.

## Build

```
cd ~/Sites/lm-review-stress-test/swiftbench
swift build -c release
ls .build/release/swiftlmd
```

## Run

```
# defaults: host 127.0.0.1, port 5400, budget 80 GB, idle 15 min
./.build/release/swiftlmd
```

### Environment variables

| var | default | meaning |
|---|---|---|
| `SWIFTLMD_HOST` | `127.0.0.1` | listen address |
| `SWIFTLMD_PORT` | `5400` | listen port |
| `SWIFTLMD_BUDGET_GB` | `80` | memory ceiling for loaded models |
| `SWIFTLMD_IDLE_MINUTES` | `15` | auto-unload threshold |
| `SWIFTLMD_SWIFTLM_BINARY` | `~/Sites/SwiftLM/.build/.../SwiftLM` | path to SwiftLM binary |

## HTTP API

### Standard OpenAI surface

- `GET /health`: trivial liveness probe
- `GET /v1/models`: enumerate everything under `~/.lmstudio/models` and `~/.cache/huggingface/hub`
- `POST /v1/chat/completions`: chat completion. Honors `stream: true`. JIT-spawns
  the target model on first call.
- `POST /v1/completions`: legacy text completion endpoint

### Broker-specific surface

- `GET /swiftlmd/loaded`: list currently loaded models with last-used time and memory
- `POST /swiftlmd/preload` body `{"model": "<id>"}`: warm a model before traffic
- `POST /swiftlmd/unload` body `{"model": "<id>"}`: force-evict a model

## Model selection

The broker accepts several id forms and resolves each to a descriptor:

- HuggingFace slug: `mlx-community/Qwen3-Coder-30B-A3B-Instruct-8bit-DWQ-lr9e8`
- Display name: `Qwen3-Coder-30B-A3B-Instruct-8bit-DWQ-lr9e8`
- Absolute path: `/Users/agoodkind/.lmstudio/models/mlx-community/...`

Use whatever your client hardcodes. `GET /v1/models` returns the canonical id
string for each entry; that one always works.

## JIT behavior

1. First request for an unloaded model
   1. Route looks up the descriptor
   2. Checks the memory budget; evicts idle models LRU-first if needed
   3. Allocates the next free port in `5500...5599`
   4. Spawns SwiftLM with the right `--model` and `--ctx-size`
   5. Polls `/v1/models` until the upstream comes up (up to 300 s)
   6. Proxies the request

2. Subsequent requests reuse the running backend without spawn overhead

3. A background task walks the router every minute and unloads any model
   whose `lastUsed` is older than `SWIFTLMD_IDLE_MINUTES`

## Structured output (JSON mode)

When a request includes `response_format` of type `json_object` or
`json_schema`, swiftlmd injects a system message instructing the model to
emit JSON. If a schema is attached, its body is included verbatim in the
instruction. This is what lifts the local Qwen Coder parse rate from
around 50% to nearly 100% in practice. No change is required on the
client side.

## Streaming

Works when the request body has `stream: true`. swiftlmd proxies the
upstream SSE byte stream back to the client in 4 KiB chunks. Clients
should expect `text/event-stream` content type.

## Failure modes

| symptom | cause | fix |
|---|---|---|
| `model not found` 404 | client id doesn't match catalog | hit `GET /v1/models` and copy an `id` |
| `cannot fit ... in memory budget` 503 | asked for a model that doesn't fit even after eviction | increase `SWIFTLMD_BUDGET_GB` or unload others first |
| `no free port` 503 | all ports 5500-5599 are in use | unload something |
| long wait on first request | cold model spawn (15-60 s) | use `/swiftlmd/preload` before traffic arrives |
| no response at all | upstream SwiftLM hung | kill the broker; it will restart everything on next launch |

## Logs

Stderr of swiftlmd goes to the controlling terminal. The SwiftLM subprocesses
tee their stdout and stderr to `~/Sites/lm-review-stress-test/configs-battery/logs/swiftlmd.log`.
Tail that file to watch live generation across all backends.

## LaunchAgent (optional)

To run as a persistent user service instead of a foreground process, drop
this plist at `~/Library/LaunchAgents/com.goodkind.swiftlmd.plist` and load
with `launchctl bootstrap gui/$(id -u) ...`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>com.goodkind.swiftlmd</string>
    <key>ProgramArguments</key>
    <array>
        <string>/Users/agoodkind/Sites/lm-review-stress-test/swiftbench/.build/release/swiftlmd</string>
    </array>
    <key>EnvironmentVariables</key>
    <dict>
        <key>SWIFTLMD_BUDGET_GB</key><string>80</string>
        <key>SWIFTLMD_IDLE_MINUTES</key><string>15</string>
        <key>PATH</key><string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
    </dict>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><true/>
    <key>StandardOutPath</key><string>/tmp/swiftlmd.stdout.log</string>
    <key>StandardErrorPath</key><string>/tmp/swiftlmd.stderr.log</string>
    <key>ProcessType</key><string>Background</string>
</dict>
</plist>
```

## Next steps

The broker is feature-complete for Phase 2. Future phases:

- **Phase 3**: swifttop dashboard gets a model-manager mode driven by `/swiftlmd/loaded`
- **Phase 4**: `/v1/models/pull` for HF downloads with SSE progress
- **Phase 5**: grammar-constrained decoding inside SwiftLM itself (replace the
  prompt-inject shunt with true `response_format` enforcement at decode time)
