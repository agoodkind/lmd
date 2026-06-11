# Embedding Throughput Productionization

Date: 2026-06-10
Status: approved
Repos: lmd (primary), lm-semantic-search (phase 3)

## Problem

Embedding the conversation corpus took about 10 hours at roughly 1 chunk per second. The machine is an M5 Max with 128GB of unified memory, and the GPU was mostly idle the whole time: 22 to 42 percent busy, 368 to 676 MHz, 7 to 10 W. The pipeline starves the GPU; the hardware is not the limit.

Four measured causes, biggest first.

### 1. Most of the GPU work is padding

A real batch from the trace: 32 chunks, 2,964 real tokens, padded to 1,103 tokens per row, for a padding ratio of 0.916. Conversation chunks average about 93 tokens, but one long chunk forces every row in the batch to pad to its length. The GPU does roughly 12x more work than the text needs.

Nothing bounds this on either side. lm-semantic-search batches 32 chunks by count. lmd (`NVEmbeddingBackend.tokenize`) pads every row to the batch max.

### 2. The model runs in float32

NVIDIA publishes NV-EmbedCode-7b-v1 only as F32 safetensors. We verified HuggingFace is the only weight source and no community conversion exists. `loadWeights` (MLXLMCommon) loads the file verbatim, with no cast and no quantization. The result: 27GB of resident weights, `mlx_active` at 30.6GB, and a 40GB process footprint. fp32 is about 2x slower than bf16 and doubles all memory.

### 3. The 2GiB MLX cache cap causes constant memory churn

The cap lives in `EmbeddingCacheLimit.swift` (`LMD_MLX_CACHE_LIMIT_GB=2`). One fp32 batch produces transients bigger than the whole cache; a single MLP intermediate is about 1.9GB. So MLX frees and re-allocates GPU buffers nonstop, the GPU stalls between kernels, and the clocks never ramp. `mlx_peak` reached 62.3GB and pushed the machine into 4.2GB of swap.

### 4. Concurrency of 4 makes everything worse

`LMD_EMBEDDING_MAX_CONCURRENCY=4` interleaves batches on one GPU queue. A batch that takes 55 to 65 seconds alone takes 170 to 200 seconds interleaved. Peak memory stacks. Queue wait summed 45,838 seconds across 10,049 requests, and one interactive query embed waited 43.7 seconds behind bulk batches.

### Ruled out

- Battery throttle: PowerMonitor logged zero transitions in 14 hours.
- Sequential per-input forwards: the backend runs one batched forward.
- Missing NAX support: the vendored mlx 0.30.6 includes the NAX JIT kernels, `is_nax_available()` passes on macOS 26.5 with the G17 GPU, and fp32 reaches NAX through the TF32 default.

## Decisions

- Token-budget batching lands in both layers. lmd enforces it exactly; lm-semantic-search shapes its requests approximately.
- bf16 happened as a one-off local disk conversion, already executed (see Phase 2).
- The MLX cache cap moves to 8GB for the embedding host. The env override and the battery shrink stay as they are.
- Embedding concurrency drops to 1, with a priority lane so small interactive requests skip the bulk queue.
- The query instruction prefix in lm-semantic-search is in scope. It is a quality fix riding the same client change.
- Rollout is instrument-first. Phase 0 lands measurement and config tweaks before any code fix, and every later phase ships with before and after bench numbers.
- The job-progress rendering UX in lm-semantic-search is out of scope here (tracked separately).

## Phase 0: measure first, plus the free config tweaks

New metrics, emitted by the embedding host through the existing `SwiftLMMetrics` SnapshotSink. They surface automatically in `/swiftlmd/metrics`, the Prometheus exposition, the trace ring, and OTLP export.

- `lmd_embed_padding_ratio` (histogram per request)
- `lmd_embed_batch_tokens_real` and `lmd_embed_batch_tokens_padded` (histograms)
- `lmd_embed_tokens_per_second` (histogram: real tokens per wall second per request)
- `lmd_embed_queue_depth` (gauge)
- `lmd_embed_queue_wait_seconds` (histogram: broker receipt to forward start)

New bench mode: `lmd bench embed`. Today lmd-bench is chat only. The embed mode feeds either a corpus file (one input per line) or a synthetic corpus shaped like the conversation data (median near 93 tokens, long tail past 1,000). It reports real tokens per second, padded slots per second, per-batch p50 and p95 latency, and `mlx_peak`.

Config tweaks in the LaunchAgent plist and defaults:

- `LMD_EMBEDDING_MAX_CONCURRENCY` goes from 4 to 1. The Phase 1 priority lane restores interactive latency.
- The embedding cache default goes from 2GiB to 8GiB (`EmbeddingCacheLimit.swift` plus `LMD_MLX_CACHE_LIMIT_GB=8`). The hard-throttle 512MiB shrink stays.

Done when: a baseline `lmd bench embed` run is recorded, and the new metrics show up in `/swiftlmd/metrics` and `/metrics`.

## Phase 1: token-budget batching and the priority lane (lmd)

In `NVEmbeddingBackend.embed`, after tokenization:

1. Sort the encoded inputs by token length.
2. Pack sub-batches greedily under a padded-slot budget: rows times the sub-batch max length stays at or under `LMD_EMBED_BATCH_TOKEN_BUDGET` (default 8192 slots), with a cap of 256 rows.
3. Run one forward per sub-batch, one after another.
4. Reassemble the pooled rows in the original input order before returning.

Edge rules: an input longer than the whole budget gets its own sub-batch, and the existing 4096-token truncation still applies first. If any sub-batch fails, the whole request fails. That preserves the current all-or-nothing contract; no partial vectors.

Priority lane: the `EmbeddingHost` actor serializes all forwards through one queue. A request with at most 2 inputs, or under 2,048 real tokens, enqueues at the front. Bulk work can afford this: after the batching fix, a bulk sub-batch costs single-digit seconds, so a priority jump delays bulk by at most one sub-batch.

Done when: `lmd_embed_padding_ratio` p50 is below 0.10 on the conversation-shaped bench corpus, bench throughput is at least 5x the Phase 0 baseline, and a single-input embed finishes in under 2 seconds while a bulk run is active.

## Phase 2: bf16 (already executed on 2026-06-10, recorded here)

What was done:

- All 290 tensors of the F32 checkpoint were cast to bf16 with an MLX script on the CPU device. Auxiliary files were copied and `torch_dtype` was patched. The output was verified: dtypes, shapes, and tensor names all match. Size went from 27GB to 14.22GB.
- The directories were swapped so the model id never changed. The bf16 weights now live at `~/.lmstudio/models/nvidia/NV-EmbedCode-7b-v1`, and the original fp32 weights at `~/.lmstudio/models/nvidia/NV-EmbedCode-7b-v1-fp32`. This matters because every lm-semantic-search codebase pins the model id in its registry `effective_config`. A new id would change the config digest, invalidate every merkle checkpoint, and force a full re-embed of every collection. Swapping the bytes under the same name avoided all of that. The naming is intentional; the `-fp32` suffix marks the original.
- Measured result: the model loads at 13.2GB (was 26.5GB). 32-input batches complete in 1.7 to 24 seconds under the same contention that used to produce 170 to 200 seconds. The interrupted ingest resumed from its checkpoint and reconciled at a pass-through rate of roughly 1,900 documents per hour.

Still to do in this phase:

- Quality gate, after the fact. Embed about 1,000 real chunks and 50 real queries with both weight sets. Require median pairwise cosine at or above 0.999 and top-10 retrieval overlap at or above 98 percent. If the gate fails, swap the directories back (the fp32 copy is intact) and re-run the affected ingests.
- Pooling precision. Cast hidden states to fp32 for the mean-pool and L2-normalize steps in `poolHiddenStates`. Cheap, and it removes the most precision-sensitive bf16 step.
- Disk reclaim. The 27GB fp32 copy stays until the quality gate passes. Deleting it after that is the operator's call.

## Phase 3: client-side shaping and the query prefix (lm-semantic-search)

- Replace the count-32 batching in `insertChunksBatched` with an estimated-token budget. The estimate is bytes divided by 4; the budget is roughly 6,000 estimated tokens per request. The server enforces exact counts anyway, so estimation error only changes request granularity.
- Add a `queryInstructionPrefix` config field. For NV-EmbedCode it defaults to `Instruct: Retrieve code or text relevant to the query.\nQuery: `, applied only to query-time embeddings in the search path. Document embeddings stay bare, so every stored vector remains valid. Other models default to no prefix.

Done when: ingest requests arrive at lmd within 2x of the slot budget, and a retrieval spot check on 20 known-answer queries does not regress (the prefix may improve it).

## End-to-end acceptance

Re-run a real conversation ingest after all phases. Targets, with the old numbers for contrast:

- Padding waste below 10 percent (was 92 percent).
- Sustained GPU utilization above 70 percent during eval windows (was 22 to 42 percent).
- Chunk throughput at least 10x the fp32 count-32 baseline.
- A single-query embed under 2 seconds during bulk indexing (was 43.7 seconds).
- `mlx_peak` below 30GB and zero swap growth (was 62.3GB and 4.2GB of swap).

## Error handling

- A sub-batch forward failure fails the whole request through the existing typed error frame. No partial vectors.
- A bf16 quality-gate failure means swapping the directories back to fp32. No code rollback is needed.
- The 8GiB cache cap carries a known risk: the cap exists because the cache once grew from 4KB to 40GB in 80 seconds. The Phase 0 bench memory report catches a recurrence before any code lands.
- If the priority lane starves bulk work (bulk latency p95 regresses past 2x), a config flag demotes it to plain FIFO.

## Out of scope

Quantization. NAX and TF32 experiments. The LaunchAgent ProcessType change. Chat and video paths. lmd HTTP API changes. The lm-semantic-search job-progress rendering UX (tracked separately).

## Appendix: lmd observability inventory (as of 2026-06-10)

HTTP on :5400:

- `/health`: liveness JSON.
- `/v1/models`: catalog with kind and capabilities.
- `/swiftlmd/loaded`: router snapshot. Allocated, reserve, and available bytes; per-model kind, size, `in_flight_requests`, `last_used`.
- `/swiftlmd/metrics`: merged JSON snapshot from the broker plus every model host. Counters, gauges, histograms, sources, and a 1024-entry trace ring.
- `/swiftlmd/traces`: the trace ring alone. Spans carry `request_id`, durations, `mlx_active`, `mlx_cache`, `mlx_peak`, and batch stats.
- `/metrics`: Prometheus exposition, gated by `LMD_ENABLE_PROMETHEUS_METRICS` or `LMD_ENABLE_METRICS`.
- `/swiftlmd/events`: SSE lifecycle stream with a 32-event backfill.
- Control: `/swiftlmd/preload`, `/swiftlmd/unload`, `/api/v1/models/load`, `/api/v1/models/unload`.

XPC: `BrokerRequest.metrics` (SwiftLMControl/BrokerProtocol.swift) serves the same merged snapshot to lmd-tui (the perf tab) and the lmd CLI.

Metric names today: `lmd_broker_allocated_bytes`, `lmd_broker_available_bytes`, `lmd_broker_loaded_models`, `lmd_broker_memory_under_pressure`, `lmd_tokens_total`, `lmd_chat_time_to_first_token_seconds`, `lmd_chat_inter_token_seconds`, `lmd_backend_request_duration_seconds`, `lmd_backend_phase_duration_seconds`, `lmd_backend_trace_events_total`.

Two trace planes:

1. `SwiftLMMetrics.withRequestSpan` plus `recordRequestSpan`, feeding the TraceRingBuffer. Exported via swift-otel when `OTEL_EXPORTER_OTLP_ENDPOINT` is set. Standard `OTEL_*` variables are honored, and phases render as child spans.
2. `BackendTrace` os_log lines under subsystem `io.goodkind.lmd`. The phase taxonomy lives in `TracePhase.swift`. Embedding lifecycle phases run `spawn_begin` through `spawn_runtime_ready` plus `shutdown_*`. Per-request phases are `request_pre_tokenize`, `request_post_tokenize` (with `batch_size`, `max_seq_len`, `total_tokens`, `padding_ratio`), `request_pre_forward`, `request_post_forward`, `request_post_pool`, `request_post_eval`, and `request_pre_return`. Router, Broker, Chat, and Video have their own phases. Notice level persists in the unified log; debug needs `log stream`. Every line carries an MLX memory snapshot unless `LMD_TRACE_DISABLE_MLX_SNAPSHOT=1`.

Continuous sampling: `SensorSampler` inside the broker samples macmon (it owns port 8765), battery, vm_stat, swap, and loadavg every `LMD_SAMPLE_INTERVAL` seconds (default 15) into `memory.jsonl` under `LMD_DATA_DIR`, and emits `monitor.sampled` os_log events. `PowerMonitor` logs its start and every level transition.

Bench and QA: `lmd bench` (chat only today; Phase 0 adds embed), `lmd embed` (one-shot), `lmd qa`.

Gaps this design fills: no padding or queue metrics, no tokens-per-second metric, no embedding bench mode.
