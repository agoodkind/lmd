# Embedding Throughput Productionization

Date: 2026-06-10
Status: approved
Repos: lmd (primary), lm-semantic-search (phase 3)

## Problem

A full conversation-corpus ingest (lm-semantic-search feeding `chat:///clyde-conversations` through lmd) ran for roughly 10 hours at about 1 chunk per second on an M5 Max with 128GB unified memory. The GPU was starved, not saturated: 22 to 42 percent busy at 368 to 676 MHz drawing 7 to 10 W during active embedding.

Measured causes, in impact order:

1. Padding waste. A real indexer batch tokenized to `batch_size=32, total_tokens=2964, max_seq_len=1103, padding_ratio=0.9160`. Conversation chunks average roughly 93 tokens; one long chunk pads the whole batch. Neither lm-semantic-search (count-32 batching) nor lmd (`NVEmbeddingBackend.tokenize` pads to batch max) bounds padded slots. Roughly 12x wasted compute on a typical full batch.
2. fp32 end to end. NVIDIA publishes NV-EmbedCode-7b-v1 only as F32 safetensors (verified: HuggingFace is the only weight source; no community conversion exists). `loadWeights` (MLXLMCommon) loads verbatim with no cast and no quantization: 27GB resident weights, `mlx_active` 30.6GB, process footprint 40GB.
3. MLX cache cap churn. The 2GiB cap (`EmbeddingCacheLimit.swift`, `LMD_MLX_CACHE_LIMIT_GB=2`) is smaller than one fp32 batch's transients (an MLP intermediate alone is roughly 1.9GB), forcing constant GPU buffer alloc and free. `mlx_peak` reached 62.3GB and pushed the machine into swap (4.2GB).
4. Concurrency 4. `LMD_EMBEDDING_MAX_CONCURRENCY=4` interleaves batches on one GPU queue: a 55 to 65 second batch stretches to 170 to 200 seconds, peak memory stacks, and queue wait summed 45,838 seconds over 10,049 requests. A single interactive query embed waited 43.7 seconds behind bulk batches.

Ruled out: battery throttle (no PowerMonitor transitions logged in 14 hours), sequential per-input forwards (the backend runs one batched forward), and NAX unavailability (the vendored mlx 0.30.6 JIT sources include the NAX kernels; `is_nax_available()` passes on macOS 26.5 with the G17 GPU; fp32 reaches NAX only via the TF32 default).

## Decisions

- Token-budget batching lands in both layers: lmd enforces exactly, lm-semantic-search shapes requests approximately.
- bf16 via a one-off local disk conversion, already executed (see Phase 2).
- MLX cache cap sized to workload: 8GB default for the embedding host, override and battery shrink unchanged.
- Embedding concurrency 1 with a priority lane for small interactive requests.
- The lm-semantic-search query instruction prefix is in scope (quality fix riding the same client change).
- Rollout is instrument-first: Phase 0 lands measurement and config tweaks before any code fix, and every later phase ships with before and after bench numbers.
- The job-progress rendering UX in lm-semantic-search is explicitly out of scope here (tracked separately).

## Phase 0: measurement plane and config tweaks

New metrics emitted by the embedding host through the existing `SwiftLMMetrics` SnapshotSink, so they surface automatically in `/swiftlmd/metrics`, the Prometheus exposition, the trace ring, and OTLP export:

- `lmd_embed_padding_ratio` (histogram per request)
- `lmd_embed_batch_tokens_real` and `lmd_embed_batch_tokens_padded` (histograms)
- `lmd_embed_tokens_per_second` (histogram, real tokens per wall second per request)
- `lmd_embed_queue_depth` (gauge)
- `lmd_embed_queue_wait_seconds` (histogram, broker receipt to forward start)

New bench surface: `lmd bench embed`. Feeds a corpus file (one input per line, or JSON with expected lengths) or a synthetic corpus replicating the conversation length distribution (median near 93 tokens with a long tail past 1,000). Reports real tokens per second, padded slots per second, per-batch p50 and p95 latency, and `mlx_peak`. The harness reuses the existing lmd-bench plumbing; embedding mode is new (today lmd-bench is chat only).

Config tweaks in the LaunchAgent plist and defaults:

- `LMD_EMBEDDING_MAX_CONCURRENCY` 4 to 1 (the priority lane in Phase 1 restores interactive latency).
- Embedding cache default 2GiB to 8GiB (`EmbeddingCacheLimit.swift` default plus `LMD_MLX_CACHE_LIMIT_GB=8`), keeping the hard-throttle 512MiB shrink.

Exit criteria: baseline `lmd bench embed` run recorded; new metrics visible in `/swiftlmd/metrics` and `/metrics`.

## Phase 1: server-side token-budget batching and priority lane (lmd)

In `NVEmbeddingBackend.embed`, after tokenization:

1. Sort encoded inputs by token length.
2. Greedily pack sub-batches under a padded-slot budget: `rows x max_seq_len_in_sub_batch <= LMD_EMBED_BATCH_TOKEN_BUDGET` (default 8192 slots), with a row cap of 256.
3. Run one forward per sub-batch, sequentially.
4. Reassemble pooled rows in original input order before returning.

A single input longer than the budget forms its own sub-batch; the existing 4096-token truncation still applies first. Any sub-batch failure fails the whole request, preserving the current all-or-nothing contract.

Priority lane: the `EmbeddingHost` actor serializes forwards through one queue. Requests with at most 2 inputs or fewer than 2,048 real tokens enqueue at the front. Bulk starvation is acceptable risk: post-fix bulk sub-batches cost single-digit seconds, so a priority jump delays bulk work by at most one sub-batch.

Exit criteria: `lmd_embed_padding_ratio` p50 below 0.10 on the conversation-shaped bench corpus; bench throughput at least 5x the Phase 0 baseline; interactive single-input embed under 2 seconds while a bulk run is active.

## Phase 2: bf16 (executed 2026-06-10, recorded here)

What was done:

- One-off conversion: all 290 tensors of the F32 checkpoint cast to bf16 with an MLX script (CPU device), auxiliary files copied, `torch_dtype` patched. Output verified: dtype, shapes, and tensor names match; 27GB to 14.22GB.
- Name-preserving swap: the bf16 weights now live at `~/.lmstudio/models/nvidia/NV-EmbedCode-7b-v1` and the original fp32 weights at `~/.lmstudio/models/nvidia/NV-EmbedCode-7b-v1-fp32`. The directory name is the model id that every lm-semantic-search codebase pins in its registry `effective_config`, and changing that id changes the config digest and invalidates merkle checkpoints, which would force a full re-embed of every collection. Keeping the id and swapping the bytes avoided that entirely. This naming is intentional and documented here; the `-fp32` suffix marks the original.
- Measured result: model loads at 13.2GB (was 26.5GB); 32-input batches complete in 1.7 to 24 seconds under the same contention that previously produced 170 to 200 seconds; the interrupted conversation ingest resumed from checkpoint and reconciled at roughly 1,900 documents per hour equivalent pass-through speed.

Remaining work in this phase:

- Quality gate, after the fact: embed roughly 1,000 real chunks and 50 real queries with both weight sets, require median pairwise cosine at or above 0.999 and top-10 retrieval overlap at or above 98 percent. On failure, swap the directories back (the fp32 copy is intact) and re-run the affected period's ingests.
- Pooling precision: cast hidden states to fp32 for the mean-pool and L2-normalize steps in `poolHiddenStates` (cheap, removes the most precision-sensitive bf16 step).
- Disk reclaim decision: the fp32 copy (27GB) stays until the quality gate passes, then deletion is the operator's call.

## Phase 3: client-side shaping and query prefix (lm-semantic-search)

- Replace count-32 batching in `insertChunksBatched` with an estimated-token budget (bytes divided by 4 as the estimate, budget roughly 6,000 estimated tokens per request). The server still enforces exact counts, so estimation error only affects request granularity.
- Add a `queryInstructionPrefix` config field, default `Instruct: Retrieve code or text relevant to the query.\nQuery: ` for NV-EmbedCode, applied only to query-time embeddings in the search path. Document embeddings stay bare, so stored vectors remain valid. Other embedding models default to no prefix.

Exit criteria: ingest requests arrive at lmd within 2x of the slot budget; a retrieval spot check on 20 known-answer queries does not regress (and may improve from the prefix).

## End-to-end acceptance

Re-run a real conversation ingest pass after all phases:

- padding waste below 10 percent (was 92 percent)
- sustained GPU utilization above 70 percent during eval windows (was 22 to 42 percent)
- chunk throughput at least 10x the fp32 count-32 baseline
- single-query embed under 2 seconds during bulk indexing (was 43.7 seconds)
- `mlx_peak` below 30GB and zero swap growth (was 62.3GB and 4.2GB swap)

## Error handling

- Sub-batch forward failure: fail the request, surface the existing typed error frame; no partial vectors.
- bf16 quality gate failure: swap directories back to fp32; no code rollback needed.
- Cache cap regression risk: if 8GiB reintroduces unbounded-growth symptoms (the cap exists because the cache once grew 4KB to 40GB in 80 seconds), the bench memory report catches it in Phase 0 before any code lands.
- Priority lane starvation: bounded by sub-batch cost; if bulk latency p95 regresses past 2x, demote the lane to a simple FIFO via config.

## Out of scope

Quantization, NAX and TF32 experiments, the LaunchAgent ProcessType change, chat and video paths, lmd HTTP API changes, and the lm-semantic-search job-progress rendering UX (tracked separately).

## Appendix: lmd observability inventory (as of 2026-06-10)

HTTP on :5400:

- `/health`: liveness JSON.
- `/v1/models`: catalog with kind and capabilities.
- `/swiftlmd/loaded`: router snapshot (allocated, reserve, available bytes; per-model kind, size, `in_flight_requests`, `last_used`).
- `/swiftlmd/metrics`: merged JSON snapshot from broker plus every model host (counters, gauges, histograms, sources, 1024-entry trace ring).
- `/swiftlmd/traces`: the trace ring alone; spans carry `request_id`, durations, `mlx_active`, `mlx_cache`, `mlx_peak`, and batch stats.
- `/metrics`: Prometheus exposition, gated by `LMD_ENABLE_PROMETHEUS_METRICS` or `LMD_ENABLE_METRICS`.
- `/swiftlmd/events`: SSE lifecycle stream with 32-event backfill.
- Control: `/swiftlmd/preload`, `/swiftlmd/unload`, `/api/v1/models/load`, `/api/v1/models/unload`.

XPC: `BrokerRequest.metrics` (SwiftLMControl/BrokerProtocol.swift) serves the same merged snapshot to lmd-tui (perf tab) and the lmd CLI.

Metric names today: `lmd_broker_allocated_bytes`, `lmd_broker_available_bytes`, `lmd_broker_loaded_models`, `lmd_broker_memory_under_pressure`, `lmd_tokens_total`, `lmd_chat_time_to_first_token_seconds`, `lmd_chat_inter_token_seconds`, `lmd_backend_request_duration_seconds`, `lmd_backend_phase_duration_seconds`, `lmd_backend_trace_events_total`.

Trace planes:

1. `SwiftLMMetrics.withRequestSpan` plus `recordRequestSpan` into the TraceRingBuffer; exported via swift-otel when `OTEL_EXPORTER_OTLP_ENDPOINT` is set (standard `OTEL_*` variables honored; phases render as child spans).
2. `BackendTrace` os_log lines, subsystem `io.goodkind.lmd`. Phase taxonomy in `TracePhase.swift`: embedding lifecycle (`spawn_begin` through `spawn_runtime_ready`, `shutdown_*`) and per-request (`request_pre_tokenize`, `request_post_tokenize` with `batch_size`, `max_seq_len`, `total_tokens`, `padding_ratio`, `request_pre_forward`, `request_post_forward`, `request_post_pool`, `request_post_eval`, `request_pre_return`), plus Router, Broker, Chat, and Video phases. Notice level persists in the unified log; debug requires `log stream`. Every line carries an MLX memory snapshot unless `LMD_TRACE_DISABLE_MLX_SNAPSHOT=1`.

Continuous sampling: `SensorSampler` in the broker samples macmon (it owns port 8765), battery, vm_stat, swap, and loadavg every `LMD_SAMPLE_INTERVAL` seconds (15) into `memory.jsonl` under `LMD_DATA_DIR`, and emits `monitor.sampled` os_log events. `PowerMonitor` logs monitor start and level transitions.

Bench and QA: `lmd bench` (chat only today; Phase 0 adds embedding), `lmd embed` (one-shot), `lmd qa`.

Known gaps this design fills: no padding or queue metrics, no tokens-per-second metric, no embedding bench mode.
