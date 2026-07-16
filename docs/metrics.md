# Metrics and tracing

`lmd-serve` publishes its operational state through a small set of HTTP
endpoints on the broker port, an XPC mirror for first-party clients, and two
optional export arms (Prometheus text exposition and OpenTelemetry). Every
number described here originates in one of two code planes:

- **SwiftLMMetrics** (`Sources/SwiftLMMetrics/`) owns the metric store: a
  process-local `SnapshotSink` that accumulates counters, gauges, histograms,
  and a bounded trace ring, plus the merge and rendering code.
- **SwiftLMTrace** (`Sources/SwiftLMTrace/`) owns the phase taxonomy
  (`TracePhase`) and the MLX memory snapshot (`MemorySnapshot`) that every
  trace event carries.

The metric names, label sets, and phase strings in this document are checked
against those modules. When the code and this document disagree, the code is
canonical; fix the document.

## Endpoints

All routes are registered in `registerRoutes` in
`Sources/lmd-serve/SwiftLMD.swift` and served on `LMD_HOST:LMD_PORT`
(`localhost:5400` by default).

| Route | Method | Returns |
| --- | --- | --- |
| `/health` | GET | `{"status":"ok","service":"swiftlmd"}`. Liveness only. |
| `/swiftlmd/loaded` | GET | The router snapshot: `allocated_gb`, `reserve_gb`, `available_gb`, and one entry per loaded model with `kind`, `size_gb`, `last_used`, `in_flight_requests`, `capabilities`, and `load_config`. |
| `/swiftlmd/metrics` | GET | The merged metrics snapshot (schema below): counters, gauges, histograms, sources, and the trace ring. |
| `/swiftlmd/traces` | GET | The same snapshot reduced to `sources` and `traces`, for clients that only want spans. |
| `/metrics` | GET | Prometheus text exposition of the merged snapshot. Registered only when the exposition is enabled (see [Prometheus exposition](#prometheus-exposition)). |
| `/swiftlmd/events` | GET | A Server-Sent-Events stream of broker lifecycle events, with the last 32 events replayed as backfill. |

The XPC control surface mirrors the metrics route: `BrokerRequest.metrics`
returns the identical JSON bytes as `BrokerResponse.metricsJSON`
(`Sources/SwiftLMControl/BrokerProtocol.swift`). `lmd-tui` reads its perf tab
through this path so it needs no HTTP port.

```
curl -s localhost:5400/swiftlmd/metrics | python3 -m json.tool
curl -s localhost:5400/swiftlmd/traces  | python3 -m json.tool
```

## The snapshot document

`/swiftlmd/metrics` serves a `MergedMetricsSnapshot`
(`Sources/SwiftLMMetrics/MetricsModels.swift`), encoded with sorted keys and
ISO 8601 dates:

```json
{
  "schema_version": 1,
  "generated_at": "2026-06-11T04:10:49Z",
  "sources": [ ... ],
  "metrics": { "counters": [...], "gauges": [...], "histograms": [...] },
  "traces": [ ... ]
}
```

`schema_version` is `swiftLMMetricsSchemaVersion`. Bump it when a field
changes shape.

Counters and gauges are `{name, value, labels}`. Histograms are running
accumulators, not bucketed distributions: `{name, count, sum, min, max, last,
labels}`. There are no quantiles; compute averages as `sum / count`.

Trace records are `MetricsTraceSpan`:

| Field | Meaning |
| --- | --- |
| `span_id`, `parent_span_id` | UUIDs. `parent_span_id` is null for top-level records. |
| `name` | A phase string (for point-in-time events) or a span name such as `embedding.request` (for completed requests). |
| `source_id` | The emitting process (see next section). |
| `model_id`, `model_kind` | The model the record belongs to. |
| `request_id` | Correlates every record of one request across processes. |
| `started_at`, `duration_ms` | Wall-clock start and duration. Point-in-time phase events have `duration_ms: 0`. |
| `attributes` | String map. Phase events carry the MLX memory fields and per-phase extras described below. |

Each process keeps its trace ring in a `TraceRingBuffer` with a capacity of
512 records, so the merged payload holds up to 512 recent records per source,
oldest evicted first.

## Sources and merging

Every process that emits metrics identifies itself as a `MetricsSource` with a
stable `source_id`:

- The broker is `source_id: "broker"` (process `lmd-serve`).
- Each model host is `source_id: "host:<kind>:<model path>"` (process
  `lmd-model-host`), stamped with `model_id` and `model_kind`.

The sink stamps `source_id` as a label on every series it stores, so merged
series never collide across processes.

Hosts push their snapshot to the broker over the host XPC session: once after
every request completes and on a two-second stats timer
(`Sources/lmd-model-host/main.swift`). The broker caches the most recent
snapshot per host (`XPCModelServer.lastMetricsSnapshot`) and merges on demand:
each metrics request takes the broker's own sink snapshot, appends the cached
host snapshots, and concatenates them (`MetricsJSON.merge`). Nothing is
aggregated across sources.

Two consequences worth knowing:

- Counters and histograms reset when their process restarts. A host that is
  unloaded disappears from `sources` along with all of its series.
- A host snapshot can be up to two seconds stale, plus whatever time has
  passed since the last request finished.

## Metric reference

### Broker gauges

Set in `brokerMetricsSnapshot` (`Sources/lmd-serve/SwiftLMD.swift`) each time
a metrics route is served, from the router's live state. Labels: `source_id`.

| Name | Meaning |
| --- | --- |
| `lmd_broker_loaded_models` | Number of currently loaded models. |
| `lmd_broker_allocated_bytes` | Total bytes the router accounts to loaded models. |
| `lmd_broker_available_bytes` | Available system memory from the router's memory reading. |
| `lmd_broker_memory_under_pressure` | `1` when the memory reading reports pressure, else `0`. |

### Embedding tuning gauges

Resolved when an embedding host spawns and stamped on the broker source (`source_id: broker`). Unlike the broker gauges above, they are not refreshed on each metrics serve, so read them as the tuning in effect since the last embedding-host spawn, not live broker state.

| Name | Meaning |
| --- | --- |
| `lmd_embed_resolved_cache_limit_bytes` | MLX allocator cache cap resolved for embedding backends (from `LMD_MLX_CACHE_LIMIT_GB`, or auto from free memory). |
| `lmd_embed_resolved_slot_budget` | Embedding batch slot budget resolved for the loaded embedding model. |

### Backend trace plane

Emitted by `SnapshotSink` as a side effect of recording trace events
(`Sources/SwiftLMMetrics/SnapshotSink.swift`).

| Name | Type | Labels | Meaning |
| --- | --- | --- | --- |
| `lmd_backend_trace_events_total` | counter | `model_id`, `model_kind`, `phase`, `source_id` | One increment per trace event. Use it to count requests per phase or to spot failure phases. |
| `lmd_backend_phase_duration_seconds` | histogram | `model_id`, `model_kind`, `phase`, `source_id` | Interval between consecutive `request_*` events of the same request, attributed to the earlier event's phase. The series labeled `phase=X` therefore measures the time spent *after* `X` until the next phase event. Tracking for a request ends at `request_pre_return` or `request_post_generate`. Lifecycle (`spawn_*`, `shutdown_*`) events produce no durations. |
| `lmd_backend_request_duration_seconds` | histogram | `model_id`, `model_kind`, `span`, `source_id` | Whole-request durations recorded when a `PhaseTracker` finishes. `span` is the span name, for example `embedding.request`. |

### Chat and video

| Name | Type | Labels | Meaning |
| --- | --- | --- | --- |
| `lmd_chat_time_to_first_token_seconds` | histogram | `model_id`, `model_kind`, `source_id` | Request start to first streamed token event (`Sources/lmd-model-host/ChatHost.swift`). |
| `lmd_chat_inter_token_seconds` | histogram | `model_id`, `model_kind`, `source_id` | Gap between consecutive streamed token events. |
| `lmd_tokens_total` | counter | `model_id`, `model_kind`, `source_id` | Tokens per completed request. For chat, the count of SSE token events the proxy observed (the child reports no structured usage). For video, `usage.totalTokens` from the backend (`Sources/LMDServeSupport/VideoChatRouting.swift`). |

Every series carries `source_id`, since the sink stamps it on each stored series (see Sources and merging). The `model_id` and `model_kind` labels apply to model-scoped series only.

### Embedding host

Emitted by the embedding model host (`source_id: host:embedding:<path>`) as it batches and runs embedding requests. Labels: `source_id`.

| Name | Type | Meaning |
| --- | --- | --- |
| `lmd_embed_batch_tokens_real` | histogram | Real (unpadded) token count per embedding batch. |
| `lmd_embed_batch_tokens_padded` | histogram | Padded token count per embedding batch, after padding inputs up to the batch shape. |
| `lmd_embed_padding_ratio` | histogram | Padding fraction of each batch, a wasted-work indicator. |
| `lmd_embed_tokens_per_second` | histogram | Embedding throughput per batch. |
| `lmd_embed_queue_depth` | gauge | Embedding requests waiting for a batch slot. |
| `lmd_embed_queue_wait_seconds` | histogram | Time an embedding request waited before admission. |

## Trace phases

Phase strings live in `TracePhase` (`Sources/SwiftLMTrace/TracePhase.swift`),
namespaced by backend kind. The same strings appear as `name` on trace
records, as the `phase` label on the backend trace metrics, and as `phase=` on
the unified-log lines under category `BackendTrace`.

**Broker** (kind-agnostic request boundaries): `request_received`,
`request_routed`, `request_started`, `request_completed`, `request_failed`,
`request_done_ack`, `request_response_sent`.

**Router**: `router_route_begin`, `router_route_end`, `router_model_spawned`,
`router_model_evicted`, `router_model_unloaded`, `router_request_done`,
`router_embedding_spawned`, `router_embedding_request_done`,
`router_embedding_unloaded`, `router_embedding_evicted`.

**Embedding** lifecycle: `spawn_begin`, `spawn_config_parsed`,
`spawn_model_constructed`, `spawn_weights_loaded`, `spawn_tokenizer_loaded`,
`spawn_runtime_ready`, `shutdown_pre`, `shutdown_runtime_nil`,
`shutdown_post_clear_cache`. Per request: `request_pre_tokenize`,
`request_post_tokenize`, `request_pre_forward`, `request_post_forward`,
`request_post_pool`, `request_post_eval`, `request_pre_return`.

**Chat** lifecycle: `spawn_begin`, `spawn_process_started`, `spawn_health_ok`,
`spawn_ready`, `shutdown_pre`, `shutdown_signaled`, `shutdown_terminated`.
Per request: `request_pre_prompt`, `request_post_prompt`,
`request_pre_generate`, `request_post_first_token`, `request_post_generate`,
`request_pre_return`.

**Video** lifecycle: `spawn_begin`, `spawn_container_loaded`, `spawn_ready`,
`shutdown_pre`, `shutdown_runtime_nil`, `shutdown_post_clear_cache`. Per
request: `request_pre_frames`, `request_post_frames`, `request_pre_generate`,
`request_post_generate`, `request_pre_return`.

**Common**: `spawn_begin`, `shutdown_pre`, `tick`.

### Memory fields on trace events

Every `BackendTrace` event snapshots the process-global MLX allocator through
`MemorySnapshot.current()` and attaches three attributes:

| Attribute | Meaning |
| --- | --- |
| `mlx_active` | Bytes in live `MLXArray` buffers (weights plus any intermediates alive at that instant). |
| `mlx_cache` | Bytes MLX's allocator holds for reuse. Bounded by the cache limit (`LMD_MLX_CACHE_LIMIT_GB`). |
| `mlx_peak` | High-water mark of MLX GPU memory since the process started. |

Because the snapshot is process-global and requests interleave, a snapshot
taken at one request's phase boundary can include memory held by another
request's in-flight evaluation. Treat per-request attribution as approximate;
treat `mlx_peak` as exact.

Phase events also carry phase-specific attributes, and every event carries the
emitting `backend_obj`, its `load_id`, and the log `level`. The rest group by
where they appear:

- **Broker request boundaries** attach `client_request_id`, `endpoint`,
  `transport`, `model_path`, `request_bytes`, `response_bytes`, `status_code`,
  `stream`, `bytes`, and `inflight`. The proxied chat hop also attaches
  `upstream_path` and `upstream_port`.
- **Embedding tokenize phases** attach `batch_size`, `max_seq_len`,
  `total_tokens`, `padding_ratio`, `padded_slots`, `sub_batches`, and
  `row_count`.
- **Completed embedding spans** (`embedding.request`) attach `input_count`,
  `outcome`, `dims`, `vector_count`, and `vectors`.
- **Completed chat spans** (`chat.request`) attach `outcome`, `token_events`,
  `status_code`, `response_bytes`, `content_type`, and `stream`.

Set `LMD_TRACE_DISABLE_MLX_SNAPSHOT=1` to force the memory fields to zero in
environments without Metal (see `docs/configuration.md`).

## Prometheus exposition

`GET /metrics` renders the merged snapshot as Prometheus text
(`Sources/SwiftLMMetrics/PrometheusExposition.swift`), content type
`text/plain; version=0.0.4`. The route exists only when the broker
environment sets `LMD_ENABLE_PROMETHEUS_METRICS` or `LMD_ENABLE_METRICS` to
`1` or `true`. These are diagnostic switches read where used, not part of the
fail-fast `BrokerConfig` seam.

Counters and gauges render natively. Each histogram renders as a `summary`
with five suffixed series carrying the accumulator fields: `_count`, `_sum`,
`_min`, `_max`, `_last`. There are no `_bucket` series.

## OpenTelemetry export

When `OTEL_EXPORTER_OTLP_ENDPOINT` is set (and non-empty), both `lmd-serve`
and `lmd-model-host` install the OTLP export arm at bootstrap
(`Sources/SwiftLMMetricsOTel/OTelExport.swift`):

- Metrics fan out to the OTLP factory alongside the in-process sink through
  one `MultiplexMetricsHandler`; the JSON endpoints keep working regardless.
- Request spans export through swift-distributed-tracing:
  `SwiftLMMetrics.withRequestSpan` opens a server span per request and each
  `PhaseTracker.mark` attaches the phase as a child span.
- Resource identity is `service.name` = the process role (`lmd-serve` or
  `lmd-model-host`) and `service.instance.id` = the `source_id`.
- Log export is disabled; logging stays on `os.Logger` (see `AGENTS.md` §5).

The OTel target is linked only in the SwiftPM build. The Tuist project omits
it, and callers guard the import with `#if canImport(SwiftLMMetricsOTel)`, so
the export arm is absent from metallib-only builds. A missing or invalid
endpoint degrades to no export rather than failing startup.

## Sensor samples

Thermal, battery, and power time series are a separate plane from metrics and
logs. The sampler writes one JSON object per line to `memory.jsonl` under
`LMD_DATA_DIR`, every `LMD_SAMPLE_INTERVAL` seconds (see
`docs/configuration.md`). Each sample
(`Sources/SwiftLMMonitor/SensorSampler.swift`) carries:

- **Identity and time**: `ts` (ISO 8601 UTC), `source` (`lmd-serve`).
- **Thermal**: `cpu_temp_c`, `gpu_temp_c`.
- **Power**: `cpu_power_w`, `gpu_power_w`, `ane_power_w`, `sys_power_w`,
  `batt_watts_signed`.
- **Battery**: `batt_pct`, `ac_state`, `power_source`.
- **CPU and GPU load**: `cpu_pct`, `gpu_pct`, `load1`.
- **Memory**: `ram_used_gb`, `pressure_free_pct`, `pages_free`, `pages_active`,
  `pages_inactive`, `pages_wired`, `pages_compressed`, and the `vm_stat`
  counters `pageouts`, `pageins`, `compressions`, `decompressions`.
- **Swap**: `swap_used`, `swap_total`, `swap_files`.

This artifact is not served over HTTP and is not part of the metrics snapshot.

## Logging plane

Unified-log events under subsystem `io.goodkind.lmd` are the logging plane, not
metrics. Each source file logs under one PascalCase category (see `AGENTS.md`
section 5), so a category names the emitting type: request routing under
`Broker` and `ModelRouter`; host lifecycle under `ModelHost`, `HostListener`,
`XPCModelServer`, `ChatHost`, and `EmbeddingHost`; sensor and power sampling
under `SensorSampler` and `PowerMonitor`; and `OSSignposter` intervals under
`Performance`. The `BackendTrace` category mirrors the trace events described
here, with the same phase strings and memory fields. The enforced category list
lives in `Tests/Fixtures/expected-categories.txt`.
