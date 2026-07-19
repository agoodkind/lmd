# Operating a running lmd

This guide is for any tool or agent that calls a running lmd and needs to know what it is doing. It covers how to reach lmd, call a model, prove what lmd is doing, and recognize why a request was refused. For install and service lifecycle, see [AGENTS.md](../AGENTS.md). For the metric and endpoint reference, see [docs/metrics.md](metrics.md).

## Overview

lmd is a local inference and embedding server that speaks the OpenAI HTTP API on `http://localhost:5400`. It runs as the `io.goodkind.lmd.serve` LaunchAgent, and its source is at `~/Sites/lmd`.

lmd runs models on the GPU through Apple MLX and Metal. CPU usage is therefore not the signal for whether lmd is busy. A model can be at full load while the CPU sits near idle. To judge lmd, read its own state, described below, rather than CPU.

The interface and port come from `LMD_HOST` and `LMD_PORT`. This guide uses the default `localhost:5400`.

## Reach lmd

Confirm lmd is up with a liveness check:

```
curl -s localhost:5400/health
# {"status":"ok","service":"swiftlmd"}
```

`/health` reports liveness only. It stays `200` whether or not a model is loaded, and whether or not inference is paused.

## Call a model

List the models lmd can serve, each with its kind:

```
curl -s localhost:5400/v1/models
```

Every entry carries a `kind` of `chat` or `embedding`. Send chat to a `chat` id, and embeddings to an `embedding` id.

- Chat: `POST /v1/chat/completions`
- Embeddings: `POST /v1/embeddings`

> Note: A chat request against an embedding id returns HTTP `400`. Call `/v1/models` and pick a `chat` id. See the Embeddings section in [README.md](../README.md).

## Check what lmd is doing

Read lmd's own state as read-only proof of whether it is idle, busy, or contending. Do not infer load from CPU.

The quickest view needs no curl:

```
lmd status
```

It prints lmd's memory allocation and one line per loaded model, each marked `[idle]` or `[busy]` with its kind, size, and last-used time. A `[busy]` line is direct proof a model is running a request. An empty list is proof nothing is loaded.

For a script, read the same state over HTTP:

```
curl -s localhost:5400/swiftlmd/loaded
```

It returns `allocated_gb`, `available_gb`, `reserve_gb`, and a per-model list that includes `in_flight_requests`. A `models` value of `[]` is positive proof nothing is loaded or in flight.

For GPU memory and per-phase timing, read the metrics snapshot:

```
curl -s localhost:5400/swiftlmd/metrics
```

Its trace records carry `mlx_active` and `mlx_peak`, the live and high-water GPU memory MLX holds. Its broker gauges report the loaded-model count and available memory. For spans correlated by `request_id` across lmd and each model host, read `/swiftlmd/traces`.

> Note: These read-only routes stay available even while inference is paused, because battery gating never touches them. You can always prove lmd's state without unpausing or restarting it.

For an OS-level cross-check of GPU activity, use macmon, or `sudo powermetrics --samplers gpu_power`. Read lmd's own signals first, and treat the OS view as secondary confirmation.

The field-by-field reference for every metric, phase, and trace attribute lives in [docs/metrics.md](metrics.md).

## Export to a collector

lmd can push its telemetry to external systems. Both are off by default:

- **OpenTelemetry**: set `OTEL_EXPORTER_OTLP_ENDPOINT` to export metrics and per-request spans to an OTLP collector. Each process identifies as `service.name` (`lmd-serve` or `lmd-model-host`) with `service.instance.id` set to its metrics source.
- **Prometheus**: set `LMD_ENABLE_PROMETHEUS_METRICS` (or `LMD_ENABLE_METRICS`) to serve Prometheus text at `GET /metrics`. Histograms render as summaries, not buckets.

lmd also samples thermal, battery, and power to `memory.jsonl` under `LMD_DATA_DIR`. See [docs/metrics.md](metrics.md) for the export contracts and the sensor field set.

## Handle a refusal or slowdown

Each state below has a cause and a recovery. Recognize the symptom, then apply the fix.

- **Battery pause.** lmd paused inference to preserve battery. New chat and embedding requests return HTTP `503` with `{"error":{"type":"service_paused","message":"service paused to preserve battery (battery)"}}`, and in-flight requests drain. lmd resumes once charge climbs back to `LMD_BATTERY_RESUME_PCT`. It also resumes immediately when on AC power in the macOS High Power energy mode, unless `LMD_BATTERY_HIGHPOWER_OVERRIDE` is disabled.
- **Slower embeddings on battery.** In a mild battery band, lmd paces embedding requests and leaves chat untouched. Connect power to lift the pacing.
- **Wrong model kind.** A chat request against an embedding id, or the reverse, returns HTTP `400`. Call `/v1/models` and pick an id whose `kind` matches the request.
- **Model unloaded after idle.** A model unloads after `LMD_IDLE_MINUTES` (chat) or `LMD_EMBEDDING_IDLE_MINUTES` (embedding). The next request reloads it, so the first call after idle is slower.
- **Not enough free memory.** lmd admits a model load only while `LMD_RESERVE_GB` stays free. Free memory, or unload another model.

The thresholds and every configuration key live in [docs/configuration.md](configuration.md).

## Read the logs

For a narrative of what lmd did, tail the unified log:

```
log stream --subsystem io.goodkind.lmd --info
```

Each source logs under a PascalCase category such as `Broker`, `ModelRouter`, or `BackendTrace`, so you can filter the stream by category. The logs are the narrative plane, and the metrics endpoints above are the state plane. [README.md](../README.md) has more log recipes.

## See Also

- [docs/metrics.md](metrics.md): the metric, endpoint, and trace reference.
- [docs/configuration.md](configuration.md): every `lmd-serve` configuration key.
- [README.md](../README.md): install, the OpenAI surface, and log recipes.
