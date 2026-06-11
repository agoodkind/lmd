# Embedding Throughput Productionization Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make local embedding throughput scale with the hardware. The work adds token-budget batching, a priority lane for small requests, a workload-sized MLX cache, embedding metrics, an embedding bench mode, and client-side request shaping.

**Architecture:** The broker process (`lmd-serve`) resolves every tuning value when it spawns an embedding host. An explicit env value wins; otherwise the value is auto-sized from free memory. The broker passes the resolved values to the host process (`lmd-model-host`) as command-line arguments. The host splits each request into sub-batches sorted by token length, keeps each sub-batch under a padded-slot budget, and runs the forwards through a queue that lets small requests jump ahead. The host reports padding, queue, and throughput metrics through the existing SwiftLMMetrics sink. On the client side, lm-semantic-search sizes its requests by estimated tokens and prepends an instruction prefix to search-query embeds.

**Tech Stack:** Swift for lmd (SwiftPM, XCTest with Nimble). Go for lm-semantic-search (stdlib testing). Python via uv for the one-off parity script.

**Spec:** `docs/superpowers/specs/2026-06-10-embedding-perf-design.md` in the lmd repo. The spec's Phase 2 weight conversion is complete; this plan covers everything else.

**Repos:**
- lmd: `/Users/agoodkind/Sites/lmd` (Tasks 1 through 15)
- lm-semantic-search: `/Users/agoodkind/Sites/lm-semantic-search` (Tasks 16 through 19)

**Code discovery policy for executors:** Both repos are indexed for semantic search. Use the lm-semantic-search MCP `search_code` tool with the absolute repo path for all discovery. Do not use bare grep or rg. Read exact line ranges with the Read tool.

**Verification commands:**
- lmd: `swift test --filter <TestClass>` per task, then `make test` and `make build` at checkpoints.
- lm-semantic-search: `go test ./internal/<pkg>/ -run <TestName> -v` per task, then `make test && make lint` at checkpoints.

---

## Phase 0: knobs, plumbing, metrics, bench

### Task 1: BrokerConfig knobs

**Files:**
- Modify: `Sources/LMDServeSupport/BrokerConfig.swift`
- Test: `Tests/LMDServeTests/BrokerConfigTests.swift`

This task adds five new configuration keys and changes how the cache key parses. Every key must be present in the environment, and a blank value means "auto" (the broker chooses). That present-but-blank rule already exists in this file for `promptCacheMaxTokens`; copy that pattern exactly for the two auto-capable keys.

- [ ] **Step 1: Write the failing tests**

Add to `BrokerConfigTests.swift` (follow the file's existing fixture helper for building a complete source; extend that helper's defaults with the new keys so existing tests keep passing):

```swift
func testEmbedKnobsParseExplicitValues() throws {
  let config = try BrokerConfig(source: fixtureSource(overrides: [
    .embedBatchTokenBudget: "8192",
    .embedBatchMaxRows: "128",
    .embedPriorityMaxInputs: "4",
    .embedPriorityMaxTokens: "1024",
    .embedPriorityLane: "false",
    .mlxCacheLimitGB: "4",
  ]))
  expect(config.embedBatchTokenBudget) == 8_192
  expect(config.embedBatchMaxRows) == 128
  expect(config.embedPriorityMaxInputs) == 4
  expect(config.embedPriorityMaxTokens) == 1_024
  expect(config.embedPriorityLaneEnabled) == false
  expect(config.mlxCacheLimitGB) == 4.0
}

func testEmbedBudgetAndCacheBlankMeansAuto() throws {
  let config = try BrokerConfig(source: fixtureSource(overrides: [
    .embedBatchTokenBudget: "",
    .mlxCacheLimitGB: "",
  ]))
  expect(config.embedBatchTokenBudget).to(beNil())
  expect(config.mlxCacheLimitGB).to(beNil())
}

func testEmbedKnobsMissingKeyFailsNamingTheKey() {
  expect {
    try BrokerConfig(source: self.fixtureSource(removing: [.embedBatchMaxRows]))
  }.to(throwError { (error: BrokerConfigError) in
    expect(error.problems.map(\.key)).to(contain(.embedBatchMaxRows))
  })
}
```

If the test file has no `fixtureSource(overrides:removing:)` helper, add one: a dictionary-backed `BrokerConfigSource` seeded with one valid value per `BrokerConfigKey.allCases`, with override/remove parameters.

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter BrokerConfigTests`
Expected: FAIL (new keys don't exist on `BrokerConfigKey`).

- [ ] **Step 3: Implement**

In `BrokerConfig.swift`:

```swift
// In BrokerConfigKey:
case embedBatchTokenBudget = "LMD_EMBED_BATCH_TOKEN_BUDGET"
case embedBatchMaxRows = "LMD_EMBED_BATCH_MAX_ROWS"
case embedPriorityMaxInputs = "LMD_EMBED_PRIORITY_MAX_INPUTS"
case embedPriorityMaxTokens = "LMD_EMBED_PRIORITY_MAX_TOKENS"
case embedPriorityLane = "LMD_EMBED_PRIORITY_LANE"

// In BrokerConfig stored properties:
/// nil means auto: the broker sizes the budget from the resolved cache cap at
/// embedding-host spawn time. Blank LMD_EMBED_BATCH_TOKEN_BUDGET requests auto.
public let embedBatchTokenBudget: Int?
public let embedBatchMaxRows: Int
public let embedPriorityMaxInputs: Int
public let embedPriorityMaxTokens: Int
public let embedPriorityLaneEnabled: Bool
/// nil means auto: the broker sizes the cache from free memory at startup and
/// at embedding-host spawn time. Blank LMD_MLX_CACHE_LIMIT_GB requests auto.
public let mlxCacheLimitGB: Double?
```

Remove the old `mlxCacheLimitBytes: Int` property (its single consumer is updated in Task 3). In `init(source:)`, parse the two blank-means-auto keys with the `promptCacheMaxTokens` pattern (present-but-blank means nil, parseable positive means value, anything else records a problem; absent records "must be defined (blank means auto)"). Parse the three plain ints with `requireInt(_:min:)` (`embedBatchMaxRows` min 1, the two priority knobs min 0) and the lane with `requireBool`. Add all six resolved values to the final `guard let` and assignment block.

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter BrokerConfigTests`
Expected: PASS (including all pre-existing tests; fix the fixture helper if any old test now reports missing keys).

- [ ] **Step 5: Commit**

```bash
git add Sources/LMDServeSupport/BrokerConfig.swift Tests/LMDServeTests/BrokerConfigTests.swift
git commit -m "Add embedding batching and priority knobs to BrokerConfig"
```

### Task 2: Auto-sizing resolver

**Files:**
- Create: `Sources/LMDServeSupport/EmbeddingTuning.swift`
- Test: `Tests/LMDServeTests/EmbeddingTuningTests.swift`

- [ ] **Step 1: Write the failing tests**

```swift
import Nimble
import XCTest

@testable import LMDServeSupport

final class EmbeddingTuningTests: XCTestCase {
  private let gib: Int64 = 1_073_741_824

  func testCacheAutoIsLargestPowerOfTwoGiBUnderOneEighthFree() {
    // 73 GiB free means 73/8 = 9.1 GiB, so 8 GiB (the spec's on-machine example).
    expect(EmbeddingTuningResolver.resolveCacheLimitBytes(
      explicitGB: nil, freeMemoryBytes: 73 * self.gib)) == Int(8 * self.gib)
  }

  func testCacheAutoClampsLowAndHigh() {
    expect(EmbeddingTuningResolver.resolveCacheLimitBytes(
      explicitGB: nil, freeMemoryBytes: 4 * self.gib)) == Int(2 * self.gib)
    expect(EmbeddingTuningResolver.resolveCacheLimitBytes(
      explicitGB: nil, freeMemoryBytes: 512 * self.gib)) == Int(16 * self.gib)
  }

  func testExplicitCacheWinsOverAuto() {
    expect(EmbeddingTuningResolver.resolveCacheLimitBytes(
      explicitGB: 4, freeMemoryBytes: 73 * self.gib)) == Int(4 * self.gib)
  }

  func testTransientBytesPerSlotFormula() {
    // dtype x (4 x intermediate + 8 x hidden) = 2 x (4x14336 + 8x4096) = 180224
    expect(EmbeddingTuningResolver.transientBytesPerSlot(
      hiddenSize: 4_096, intermediateSize: 14_336, dtypeBytes: 2)) == 180_224
  }

  func testBudgetAutoFitsTwiceTransientsInCacheRoundedTo1024() {
    // 8 GiB / (2 x 180224) = 23831, so 23552 (multiple of 1024), within [2048, 32768].
    expect(EmbeddingTuningResolver.resolveSlotBudget(
      explicit: nil, cacheLimitBytes: Int(8 * self.gib), transientBytesPerSlot: 180_224)) == 23_552
  }

  func testBudgetAutoClamps() {
    expect(EmbeddingTuningResolver.resolveSlotBudget(
      explicit: nil, cacheLimitBytes: Int(2 * self.gib), transientBytesPerSlot: 4_000_000)) == 2_048
    expect(EmbeddingTuningResolver.resolveSlotBudget(
      explicit: nil, cacheLimitBytes: Int(16 * self.gib), transientBytesPerSlot: 1_000)) == 32_768
  }

  func testExplicitBudgetWins() {
    expect(EmbeddingTuningResolver.resolveSlotBudget(
      explicit: 8_192, cacheLimitBytes: Int(2 * self.gib), transientBytesPerSlot: 180_224)) == 8_192
  }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter EmbeddingTuningTests`
Expected: FAIL (type does not exist).

- [ ] **Step 3: Implement**

```swift
//
//  EmbeddingTuning.swift
//  LMDServeSupport
//
//  Resolves the embedding host's tuning values. Explicit configuration always
//  wins; auto values derive from free unified memory and a worst-case
//  per-slot transient estimate. The cache cap resolves first, then the slot
//  budget fits inside it (spec: docs/superpowers/specs/2026-06-10-embedding-perf-design.md).
//

import Foundation

/// The fully resolved tuning bundle passed to one embedding host spawn.
public struct EmbeddingHostTuning: Equatable, Sendable {
  public let cacheLimitBytes: Int
  public let slotBudget: Int
  public let maxRows: Int
  public let priorityMaxInputs: Int
  public let priorityMaxTokens: Int
  public let priorityLaneEnabled: Bool
  public let maxConcurrentForwards: Int

  public init(
    cacheLimitBytes: Int, slotBudget: Int, maxRows: Int, priorityMaxInputs: Int,
    priorityMaxTokens: Int, priorityLaneEnabled: Bool, maxConcurrentForwards: Int
  ) {
    self.cacheLimitBytes = cacheLimitBytes
    self.slotBudget = slotBudget
    self.maxRows = maxRows
    self.priorityMaxInputs = priorityMaxInputs
    self.priorityMaxTokens = priorityMaxTokens
    self.priorityLaneEnabled = priorityLaneEnabled
    self.maxConcurrentForwards = maxConcurrentForwards
  }
}

public enum EmbeddingTuningResolver {
  static let gibibyte: Int64 = 1_073_741_824
  static let minCacheBytes = Int(2 * gibibyte)
  static let maxCacheBytes = Int(16 * gibibyte)
  static let minSlotBudget = 2_048
  static let maxSlotBudget = 32_768
  static let slotBudgetGranularity = 1_024
  /// NV-EmbedCode-7b-v1 dimensions (config.json: hidden 4096, intermediate
  /// 14336) at bf16. A different embedding model is tuned via the explicit
  /// knobs rather than new constants here.
  public static let defaultHiddenSize = 4_096
  public static let defaultIntermediateSize = 14_336
  public static let defaultDtypeBytes = 2

  /// Worst-case live transient bytes one padded slot contributes to a forward:
  /// the gate/up/SiLU/down MLP intermediates (4 x intermediate) plus residual,
  /// norm, QKV, and attention-output activations (8 x hidden), at the loaded
  /// dtype width.
  public static func transientBytesPerSlot(
    hiddenSize: Int, intermediateSize: Int, dtypeBytes: Int
  ) -> Int {
    dtypeBytes * (4 * intermediateSize + 8 * hiddenSize)
  }

  /// Explicit GB wins. Auto: the largest power-of-two GiB at or under one
  /// eighth of free memory, clamped to the 2 GiB to 16 GiB band.
  public static func resolveCacheLimitBytes(explicitGB: Double?, freeMemoryBytes: Int64) -> Int {
    if let explicitGB {
      return Int(explicitGB * Double(gibibyte))
    }
    let eighthGiB = Double(freeMemoryBytes) / 8.0 / Double(gibibyte)
    var chosenGiB = 2
    while chosenGiB * 2 <= 16 && Double(chosenGiB * 2) <= eighthGiB {
      chosenGiB *= 2
    }
    let bytes = chosenGiB * Int(gibibyte)
    return min(max(bytes, minCacheBytes), maxCacheBytes)
  }

  /// Explicit wins. Auto: the largest budget whose worst-case transients,
  /// doubled for headroom, fit inside the cache cap; rounded down to a
  /// multiple of 1024 and clamped to the 2048 to 32768 band.
  public static func resolveSlotBudget(
    explicit: Int?, cacheLimitBytes: Int, transientBytesPerSlot: Int
  ) -> Int {
    if let explicit {
      return explicit
    }
    let raw = cacheLimitBytes / (2 * max(transientBytesPerSlot, 1))
    let rounded = (raw / slotBudgetGranularity) * slotBudgetGranularity
    return min(max(rounded, minSlotBudget), maxSlotBudget)
  }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter EmbeddingTuningTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/LMDServeSupport/EmbeddingTuning.swift Tests/LMDServeTests/EmbeddingTuningTests.swift
git commit -m "Add embedding tuning resolver with cache and slot-budget auto-sizing"
```

### Task 3: Plumb tuning from broker to host argv to backend

**Files:**
- Modify: `Sources/lmd-serve/XPCModelServer.swift` (init plus `spawn()` argv)
- Modify: `Sources/lmd-serve/SwiftLMD.swift` (spawner closure near line 524; startup cache set near line 465)
- Modify: `Sources/lmd-model-host/HostArguments.swift`
- Modify: `Sources/lmd-model-host/main.swift`
- Test: `Tests/LMDModelHostTests/HostArgumentsTests.swift`

- [ ] **Step 1: Write the failing HostArguments tests**

Add to `HostArgumentsTests.swift`:

```swift
func testParsesEmbeddingTuningFlags() {
  let args = HostArguments.parse([
    "--model", "/m", "--kind", "embedding", "--host-service", "svc",
    "--mlx-cache-limit-bytes", "8589934592",
    "--embed-slot-budget", "23552",
    "--embed-max-rows", "256",
    "--embed-priority-max-inputs", "2",
    "--embed-priority-max-tokens", "2048",
    "--embed-priority-lane", "1",
    "--embed-max-forwards", "1",
  ])
  expect(args?.mlxCacheLimitBytes) == 8_589_934_592
  expect(args?.embedSlotBudget) == 23_552
  expect(args?.embedMaxRows) == 256
  expect(args?.embedPriorityMaxInputs) == 2
  expect(args?.embedPriorityMaxTokens) == 2_048
  expect(args?.embedPriorityLane) == true
  expect(args?.embedMaxForwards) == 1
}

func testEmbeddingTuningFlagsAreOptional() {
  let args = HostArguments.parse(["--model", "/m", "--kind", "embedding", "--host-service", "svc"])
  expect(args).toNot(beNil())
  expect(args?.mlxCacheLimitBytes).to(beNil())
  expect(args?.embedSlotBudget).to(beNil())
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter HostArgumentsTests`
Expected: FAIL (fields don't exist).

- [ ] **Step 3: Implement HostArguments**

Add to the struct and parser (same `while index + 1 < argv.count` switch):

```swift
let mlxCacheLimitBytes: Int?
let embedSlotBudget: Int?
let embedMaxRows: Int?
let embedPriorityMaxInputs: Int?
let embedPriorityMaxTokens: Int?
let embedPriorityLane: Bool?
let embedMaxForwards: Int?

// in the switch:
case "--mlx-cache-limit-bytes": mlxCacheLimitBytes = Int(argv[index + 1])
case "--embed-slot-budget": embedSlotBudget = Int(argv[index + 1])
case "--embed-max-rows": embedMaxRows = Int(argv[index + 1])
case "--embed-priority-max-inputs": embedPriorityMaxInputs = Int(argv[index + 1])
case "--embed-priority-max-tokens": embedPriorityMaxTokens = Int(argv[index + 1])
case "--embed-priority-lane": embedPriorityLane = argv[index + 1] == "1"
case "--embed-max-forwards": embedMaxForwards = Int(argv[index + 1])
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter HostArgumentsTests`
Expected: PASS.

- [ ] **Step 5: Wire XPCModelServer argv**

`XPCModelServer` init gains `embeddingTuning: EmbeddingHostTuning? = nil` (stored). In `spawn()` after the existing optional flags:

```swift
if let tuning = embeddingTuning {
  arguments.append(contentsOf: [
    "--mlx-cache-limit-bytes", String(tuning.cacheLimitBytes),
    "--embed-slot-budget", String(tuning.slotBudget),
    "--embed-max-rows", String(tuning.maxRows),
    "--embed-priority-max-inputs", String(tuning.priorityMaxInputs),
    "--embed-priority-max-tokens", String(tuning.priorityMaxTokens),
    "--embed-priority-lane", tuning.priorityLaneEnabled ? "1" : "0",
    "--embed-max-forwards", String(tuning.maxConcurrentForwards),
  ])
}
```

- [ ] **Step 6: Resolve tuning in the spawner closure and log it**

In `SwiftLMD.swift`, inside the `spawner:` closure (the `XPCModelServer(...)` construction around line 524), before constructing the server:

```swift
var embeddingTuning: EmbeddingHostTuning?
if kind == .embedding {
  let freeBytes = memoryProbe().availableBytes
  let cacheBytes = EmbeddingTuningResolver.resolveCacheLimitBytes(
    explicitGB: config.mlxCacheLimitGB, freeMemoryBytes: freeBytes)
  let perSlot = EmbeddingTuningResolver.transientBytesPerSlot(
    hiddenSize: EmbeddingTuningResolver.defaultHiddenSize,
    intermediateSize: EmbeddingTuningResolver.defaultIntermediateSize,
    dtypeBytes: EmbeddingTuningResolver.defaultDtypeBytes)
  let slotBudget = EmbeddingTuningResolver.resolveSlotBudget(
    explicit: config.embedBatchTokenBudget,
    cacheLimitBytes: cacheBytes,
    transientBytesPerSlot: perSlot)
  let tuning = EmbeddingHostTuning(
    cacheLimitBytes: cacheBytes,
    slotBudget: slotBudget,
    maxRows: config.embedBatchMaxRows,
    priorityMaxInputs: config.embedPriorityMaxInputs,
    priorityMaxTokens: config.embedPriorityMaxTokens,
    priorityLaneEnabled: config.embedPriorityLaneEnabled,
    maxConcurrentForwards: config.embeddingMaxConcurrency)
  embeddingTuning = tuning
  log.notice(
    "embedding.tuning_resolved model=\(model.id, privacy: .public) cache_bytes=\(tuning.cacheLimitBytes, privacy: .public) slot_budget=\(tuning.slotBudget, privacy: .public) max_rows=\(tuning.maxRows, privacy: .public) forwards=\(tuning.maxConcurrentForwards, privacy: .public) lane=\(tuning.priorityLaneEnabled, privacy: .public)"
  )
  SwiftLMMetrics.setGauge("lmd_embed_resolved_cache_limit_bytes", Double(tuning.cacheLimitBytes))
  SwiftLMMetrics.setGauge("lmd_embed_resolved_slot_budget", Double(tuning.slotBudget))
}
```

Pass `embeddingTuning: embeddingTuning` to the `XPCModelServer` init. Verify the memory reading's field name (`availableBytes`) against the `brokerLoadedSnapshot` usage in the same file; adjust if the probe returns a different shape.

Update the startup cache line (near 465) from the removed `config.mlxCacheLimitBytes` to:

```swift
setConfiguredEmbeddingCacheLimitBytes(
  EmbeddingTuningResolver.resolveCacheLimitBytes(
    explicitGB: config.mlxCacheLimitGB,
    freeMemoryBytes: memoryProbe().availableBytes))
```

(If `memoryProbe` is not yet defined at that line, move this call to just after the probe is constructed.)

- [ ] **Step 7: Consume in the host**

In `Sources/lmd-model-host/main.swift`, where `embeddingHost` is constructed for `args.kind == .embedding`:

```swift
if let cacheBytes = args.mlxCacheLimitBytes {
  setConfiguredEmbeddingCacheLimitBytes(cacheBytes)
}
embeddingHost = EmbeddingHost(modelPath: args.modelPath, tuning: args.embeddingRuntimeTuning())
```

Add to `HostArguments` (same file as the struct):

```swift
/// The tuning the embedding backend and queue consume, with hardcoded
/// fallbacks for a host launched without tuning flags (tests, manual runs).
func embeddingRuntimeTuning() -> EmbeddingRuntimeTuning {
  EmbeddingRuntimeTuning(
    slotBudget: embedSlotBudget ?? 8_192,
    maxRows: embedMaxRows ?? 256,
    priorityMaxInputs: embedPriorityMaxInputs ?? 2,
    priorityMaxTokens: embedPriorityMaxTokens ?? 2_048,
    priorityLaneEnabled: embedPriorityLane ?? true,
    maxConcurrentForwards: embedMaxForwards ?? 1)
}
```

`EmbeddingRuntimeTuning` is a new plain struct. Create `Sources/SwiftLMEmbed/EmbeddingRuntimeTuning.swift` with exactly those six fields, a public memberwise init, and `static let fallback` carrying the same defaults. `EmbeddingHost.init(modelPath:tuning:)` stores it; Task 7 consumes it.

- [ ] **Step 8: Build and run the full affected test suites**

Run: `swift build && swift test --filter HostArgumentsTests && swift test --filter BrokerConfigTests`
Expected: build succeeds, tests PASS.

- [ ] **Step 9: Commit**

```bash
git add Sources/lmd-serve/XPCModelServer.swift Sources/lmd-serve/SwiftLMD.swift Sources/lmd-model-host/HostArguments.swift Sources/lmd-model-host/main.swift Sources/lmd-model-host/EmbeddingHost.swift Sources/SwiftLMEmbed/EmbeddingRuntimeTuning.swift Tests/LMDModelHostTests/HostArgumentsTests.swift
git commit -m "Plumb resolved embedding tuning from broker spawn to host argv"
```

### Task 4: Metrics gateway gains observeValue

**Files:**
- Modify: `Sources/SwiftLMMetrics/Bootstrap.swift`
- Modify (if needed): `Sources/SwiftLMMetrics/SnapshotSink.swift`
- Test: `Tests/SwiftLMMetricsTests/SnapshotSinkFactoryTests.swift`

The metrics gateway can record gauges, counters, and time durations, but it has no entry point for a plain number like a ratio or a rate. Padding ratio and tokens-per-second are plain numbers. This task adds `observeValue`, a histogram entry point backed by swift-metrics `Recorder`.

- [ ] **Step 1: Write the failing test**

```swift
func testObserveValueLandsInSnapshotHistogram() {
  SwiftLMMetrics.observeValue("test_unitless_histogram", 0.916)
  SwiftLMMetrics.observeValue("test_unitless_histogram", 0.1)
  let snapshot = SwiftLMMetrics.sink.snapshot()
  let histogram = snapshot.metrics.histograms.first { $0.name == "test_unitless_histogram" }
  expect(histogram).toNot(beNil())
  expect(histogram?.count) == 2
  expect(histogram?.last) == 0.1
  expect(histogram?.max) == 0.916
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter SnapshotSinkFactoryTests`
Expected: FAIL (`observeValue` undefined).

- [ ] **Step 3: Implement**

In `Bootstrap.swift` beside `observeSeconds`:

```swift
/// Record a unitless value (a ratio, a rate) into a histogram.
public static func observeValue(
  _ name: String, _ value: Double, labels: [(String, String)] = []
) {
  Recorder(label: name, dimensions: labels, aggregate: true).record(value)
}
```

If the test still fails because `SnapshotSink.makeRecorder` does not aggregate into `MetricHistogram`, implement it there mirroring the Timer handler (count, sum, min, max, last per label set).

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter SnapshotSinkFactoryTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/SwiftLMMetrics/Bootstrap.swift Sources/SwiftLMMetrics/SnapshotSink.swift Tests/SwiftLMMetricsTests/SnapshotSinkFactoryTests.swift
git commit -m "Add observeValue histogram entry point to SwiftLMMetrics"
```

### Task 5: Phase-0 padding and throughput metrics in the existing embed path

**Files:**
- Modify: `Sources/SwiftLMEmbed/NVEmbeddingBackend.swift` (`embed(inputs:)`)

This task has no new unit test. The values only exist during a live forward pass, so Task 14's bench run is the verification. Keep the change purely additive.

- [ ] **Step 1: Implement**

In `embed(inputs:)`: capture `let forwardStarted = DispatchTime.now()` right after the post-tokenize trace line, and after `pooled.eval()` emit:

```swift
let elapsedSeconds =
  Double(DispatchTime.now().uptimeNanoseconds - forwardStarted.uptimeNanoseconds) / 1_000_000_000
SwiftLMMetrics.observeValue("lmd_embed_padding_ratio", batch.stats.paddingRatio)
SwiftLMMetrics.observeValue(
  "lmd_embed_batch_tokens_real", Double(batch.stats.totalTokens))
SwiftLMMetrics.observeValue(
  "lmd_embed_batch_tokens_padded", Double(batch.stats.batchSize * batch.stats.maxSeqLen))
if elapsedSeconds > 0 {
  SwiftLMMetrics.observeValue(
    "lmd_embed_tokens_per_second", Double(batch.stats.totalTokens) / elapsedSeconds)
}
```

Add `import SwiftLMMetrics` if absent.

- [ ] **Step 2: Build**

Run: `swift build`
Expected: success.

- [ ] **Step 3: Commit**

```bash
git add Sources/SwiftLMEmbed/NVEmbeddingBackend.swift
git commit -m "Emit padding and throughput metrics from NVEmbeddingBackend embed"
```

### Task 6: Sub-batch packer (pure, TDD)

**Files:**
- Create: `Sources/SwiftLMEmbed/EmbeddingBatchPacker.swift`
- Test: `Tests/SwiftLMEmbedTests/EmbeddingBatchPackerTests.swift`

- [ ] **Step 1: Write the failing tests**

```swift
import Nimble
import XCTest

@testable import SwiftLMEmbed

final class EmbeddingBatchPackerTests: XCTestCase {
  func testEmptyInputPacksToNoGroups() {
    expect(EmbeddingBatchPacker.pack(lengths: [], slotBudget: 8_192, maxRows: 256)) == []
  }

  func testSingleOversizeInputGetsItsOwnGroup() {
    let groups = EmbeddingBatchPacker.pack(lengths: [10_000], slotBudget: 8_192, maxRows: 256)
    expect(groups) == [[0]]
  }

  func testPacksShortInputsUpToSlotBudget() {
    // 100 inputs of length 100: budget 1000 slots means 10 rows per group.
    let groups = EmbeddingBatchPacker.pack(
      lengths: Array(repeating: 100, count: 100), slotBudget: 1_000, maxRows: 256)
    expect(groups.count) == 10
    expect(groups.allSatisfy { $0.count == 10 }) == true
  }

  func testMaxRowsClosesGroupBeforeBudget() {
    let groups = EmbeddingBatchPacker.pack(
      lengths: Array(repeating: 1, count: 10), slotBudget: 8_192, maxRows: 4)
    expect(groups.map(\.count)) == [4, 4, 2]
  }

  func testSortsByLengthSoMixedBatchSplitsLongFromShort() {
    // One 1000-length input among 31 of length 100. Budget 3200: the long one
    // must not drag the short ones to 1000 slots each.
    var lengths = Array(repeating: 100, count: 31)
    lengths.append(1_000)
    let groups = EmbeddingBatchPacker.pack(lengths: lengths, slotBudget: 3_200, maxRows: 256)
    let longGroup = groups.first { $0.contains(31) }
    expect(longGroup?.count) == 1
  }

  func testEveryIndexAppearsExactlyOnce() {
    let lengths = (0..<57).map { ($0 * 37) % 900 + 1 }
    let groups = EmbeddingBatchPacker.pack(lengths: lengths, slotBudget: 2_048, maxRows: 8)
    let all = groups.flatMap { $0 }.sorted()
    expect(all) == Array(0..<57)
  }

  func testGroupSlotsNeverExceedBudgetExceptSingletons() {
    let lengths = (0..<200).map { ($0 * 53) % 1_500 + 1 }
    let groups = EmbeddingBatchPacker.pack(lengths: lengths, slotBudget: 4_096, maxRows: 64)
    for group in groups where group.count > 1 {
      let maxLen = group.map { lengths[$0] }.max() ?? 0
      expect(group.count * maxLen) <= 4_096
    }
  }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter EmbeddingBatchPackerTests`
Expected: FAIL (type does not exist).

- [ ] **Step 3: Implement**

```swift
//
//  EmbeddingBatchPacker.swift
//  SwiftLMEmbed
//
//  Packs tokenized inputs into sub-batches under a padded-slot budget.
//  Padded slots for a group are rows x the group's longest input, which is
//  exactly the work the forward pass performs, so the budget bounds wasted
//  padding compute directly.
//

enum EmbeddingBatchPacker {
  /// Returns groups of indexes into `lengths`. Inputs are visited in
  /// ascending length order so short inputs never pad to a long input's
  /// length. A group closes when adding the next input would push
  /// rows x groupMaxLength past `slotBudget` or rows past `maxRows`. An input
  /// longer than the whole budget forms a group of one. Every index lands in
  /// exactly one group.
  static func pack(lengths: [Int], slotBudget: Int, maxRows: Int) -> [[Int]] {
    precondition(slotBudget > 0, "slotBudget must be positive")
    precondition(maxRows > 0, "maxRows must be positive")
    let ascending = lengths.indices.sorted { lengths[$0] < lengths[$1] }
    var groups: [[Int]] = []
    var current: [Int] = []
    var currentMaxLength = 0
    for index in ascending {
      let length = max(lengths[index], 1)
      let prospectiveMax = max(currentMaxLength, length)
      let prospectiveSlots = (current.count + 1) * prospectiveMax
      let wouldOverflow = prospectiveSlots > slotBudget || current.count + 1 > maxRows
      if !current.isEmpty && wouldOverflow {
        groups.append(current)
        current = []
        currentMaxLength = 0
      }
      current.append(index)
      currentMaxLength = max(currentMaxLength, length)
    }
    if !current.isEmpty {
      groups.append(current)
    }
    return groups
  }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter EmbeddingBatchPackerTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/SwiftLMEmbed/EmbeddingBatchPacker.swift Tests/SwiftLMEmbedTests/EmbeddingBatchPackerTests.swift
git commit -m "Add length-sorted slot-budget packer for embedding sub-batches"
```

### Task 7: embed() runs packed sub-batches and reassembles in order

**Files:**
- Modify: `Sources/SwiftLMEmbed/NVEmbeddingBackend.swift`
- Modify: `Sources/SwiftLMEmbed/EmbeddingBackendFactory.swift` (pass tuning through)
- Modify: `Sources/lmd-model-host/EmbeddingHost.swift` (pass tuning to factory)
- Test: `Tests/SwiftLMEmbedTests/NVEmbeddingBackendTests.swift`

- [ ] **Step 1: Write the failing parity test**

Add to `NVEmbeddingBackendTests.swift` (uses the tiny-model pattern; runs under `withMLXMetallib`):

```swift
func testPackedEmbedMatchesSingleBatchVectors() throws {
  try withMLXMetallib {
    let configuration = NVMistralBiDirectionalConfiguration(
      hiddenSize: 8, hiddenLayers: 1, intermediateSize: 16,
      attentionHeads: 2, keyValueHeads: 1, vocabularySize: 32)
    let model = NVMistralBiDirectionalModel(configuration)
    // Three inputs of unequal token length, pre-encoded.
    let encoded: [[Int]] = [[1, 3, 4, 5, 6], [1, 5], [1, 7, 8]]
    let meta = metadata(dimension: 8)

    let single = NVEmbeddingBackend.forwardEncoded(
      encoded: encoded, model: model, metadata: meta,
      slotBudget: 1_000, maxRows: 256)
    let packed = NVEmbeddingBackend.forwardEncoded(
      encoded: encoded, model: model, metadata: meta,
      slotBudget: 6, maxRows: 2)

    expect(packed.count) == 3
    for (singleRow, packedRow) in zip(single, packed) {
      assertVector(packedRow, approximately: singleRow)
    }
  }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter NVEmbeddingBackendTests/testPackedEmbedMatchesSingleBatchVectors`
Expected: FAIL (`forwardEncoded` undefined).

- [ ] **Step 3: Restructure NVEmbeddingBackend**

Split `embed(inputs:)` into testable stages:

```swift
/// Encode each input with truncation to the metadata's max sequence length.
func encodeInputs(_ inputs: [String], tokenizer: any MLXLMCommon.Tokenizer) -> [[Int]] {
  inputs.map { input in
    let encoded = tokenizer.encode(text: input, addSpecialTokens: true)
    if encoded.count > metadata.maxSequenceLength {
      return Array(encoded.prefix(metadata.maxSequenceLength))
    }
    return encoded
  }
}

/// Pad one group of already-encoded inputs into a forward-ready batch.
/// (This is the existing tokenize() padding body, operating on token arrays
/// instead of strings; keep NVEmbeddingBatch and its stats unchanged.)
func padEncoded(_ encodedGroup: [[Int]]) -> NVEmbeddingBatch { ... }

/// Static forward helper shared by embed() and the parity test: pack, run one
/// forward per group, pool, and reassemble rows in original input order.
static func forwardEncoded(
  encoded: [[Int]],
  model: NVMistralBiDirectionalModel,
  metadata: NVEmbeddingMetadata,
  slotBudget: Int,
  maxRows: Int
) -> [[Float]] { ... }
```

`embed(inputs:)` becomes: encode, then `EmbeddingBatchPacker.pack` on lengths, then per-group pad/forward/pool/eval, then write rows back to a `[[Float]?]` by original index, then return unwrapped rows. Aggregate stats across groups for the Task 5 metrics: the request's padding ratio is `1 - totalReal/totalSlots` summed over groups, and tokens/sec covers the whole request. The trace lines stay; post-tokenize extras gain `"sub_batches": "\(groups.count)"`, and pre/post-forward fire once per request around the group loop.

`NVEmbeddingBackend` gains `let tuning: EmbeddingRuntimeTuning` (from Task 3), used for `slotBudget` and `maxRows`. `EmbeddingBackendFactory.makeBackend(descriptor:)` gains `tuning: EmbeddingRuntimeTuning = .fallback` and passes it to the NV initializer; `EmbeddingHost.load()` passes its stored tuning.

- [ ] **Step 4: Run the full embed test suite**

Run: `swift test --filter SwiftLMEmbedTests`
Expected: PASS, including the pre-existing pooling and tiny-model tests.

- [ ] **Step 5: Commit**

```bash
git add Sources/SwiftLMEmbed/ Sources/lmd-model-host/EmbeddingHost.swift Tests/SwiftLMEmbedTests/
git commit -m "Run NV embedding forwards as packed sub-batches with ordered reassembly"
```

### Task 8: countTokens on the backend protocol

**Files:**
- Modify: `Sources/SwiftLMBackend/EmbeddingBackend.swift`
- Modify: `Sources/SwiftLMEmbed/NVEmbeddingBackend.swift`
- Test: `Tests/SwiftLMBackendTests/EmbeddingBackendTests.swift` (create if absent)

- [ ] **Step 1: Write the failing test**

```swift
import Nimble
import XCTest

@testable import SwiftLMBackend

private final class StubEmbeddingBackend: EmbeddingBackendProtocol, @unchecked Sendable {
  var modelID = "stub"
  var sizeBytes: Int64 = 0
  func launch() async throws {}
  func shutdown() {}
  func embed(inputs: [String]) async throws -> [[Float]] { [] }
}

final class EmbeddingBackendTests: XCTestCase {
  func testDefaultCountTokensEstimatesFourBytesPerToken() {
    let backend = StubEmbeddingBackend()
    // 8 bytes is 2 tokens; 9 bytes rounds up to 3; empty floors at 1.
    expect(backend.countTokens(inputs: ["abcdefgh"])) == 2
    expect(backend.countTokens(inputs: ["abcdefghi"])) == 3
    expect(backend.countTokens(inputs: [""])) == 1
    expect(backend.countTokens(inputs: ["abcdefgh", "abcdefgh"])) == 4
  }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter EmbeddingBackendTests`
Expected: FAIL (`countTokens` undefined).

- [ ] **Step 3: Implement**

Declare `func countTokens(inputs: [String]) -> Int` in `EmbeddingBackendProtocol` so overrides dispatch dynamically, with the default in the protocol extension:

```swift
/// Total token estimate for a request, used only for priority-lane
/// classification. The default approximates four UTF-8 bytes per token with a
/// per-input floor of one; tokenizer-owning backends override with real counts.
public func countTokens(inputs: [String]) -> Int {
  inputs.reduce(0) { total, input in
    total + max((input.utf8.count + 3) / 4, 1)
  }
}
```

NV override in `NVEmbeddingBackend`:

```swift
public func countTokens(inputs: [String]) -> Int {
  guard let runtime else {
    return inputs.reduce(0) { $0 + max(($1.utf8.count + 3) / 4, 1) }
  }
  return encodeInputs(inputs, tokenizer: runtime.tokenizer)
    .reduce(0) { $0 + max($1.count, 1) }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter EmbeddingBackendTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/SwiftLMBackend/EmbeddingBackend.swift Sources/SwiftLMEmbed/NVEmbeddingBackend.swift Tests/SwiftLMBackendTests/
git commit -m "Add countTokens to the embedding backend protocol"
```

### Task 9: Priority queue in the embedding host

**Files:**
- Create: `Sources/lmd-model-host/EmbeddingJobQueue.swift`
- Modify: `Sources/lmd-model-host/EmbeddingHost.swift`
- Test: `Tests/LMDModelHostTests/EmbeddingJobQueueTests.swift`

- [ ] **Step 1: Write the failing tests**

```swift
import Nimble
import XCTest

@testable import lmd_model_host

final class EmbeddingJobQueueTests: XCTestCase {
  func testPriorityAcquiresBeforeEarlierNormalWaiters() async {
    let queue = EmbeddingJobQueue(maxConcurrent: 1, laneEnabled: true)
    let order = OrderRecorder()
    await queue.acquire(priority: false)  // occupy the slot

    let normal = Task {
      await queue.acquire(priority: false)
      await order.append("normal")
      await queue.release()
    }
    try? await Task.sleep(nanoseconds: 50_000_000)
    let priority = Task {
      await queue.acquire(priority: true)
      await order.append("priority")
      await queue.release()
    }
    try? await Task.sleep(nanoseconds: 50_000_000)

    await queue.release()  // free the slot; priority must win
    _ = await priority.value
    _ = await normal.value
    let recorded = await order.values
    expect(recorded) == ["priority", "normal"]
  }

  func testLaneDisabledIsStrictFIFO() async {
    let queue = EmbeddingJobQueue(maxConcurrent: 1, laneEnabled: false)
    let order = OrderRecorder()
    await queue.acquire(priority: false)

    let first = Task {
      await queue.acquire(priority: false)
      await order.append("first")
      await queue.release()
    }
    try? await Task.sleep(nanoseconds: 50_000_000)
    let second = Task {
      await queue.acquire(priority: true)
      await order.append("second")
      await queue.release()
    }
    try? await Task.sleep(nanoseconds: 50_000_000)

    await queue.release()
    _ = await first.value
    _ = await second.value
    let recorded = await order.values
    expect(recorded) == ["first", "second"]
  }

  func testMaxConcurrentTwoAdmitsTwoWithoutWaiting() async {
    let queue = EmbeddingJobQueue(maxConcurrent: 2, laneEnabled: true)
    await queue.acquire(priority: false)
    await queue.acquire(priority: false)  // must not suspend
    let depth = await queue.waitingCount
    expect(depth) == 0
    await queue.release()
    await queue.release()
  }
}

private actor OrderRecorder {
  private(set) var values: [String] = []
  func append(_ value: String) { values.append(value) }
}
```

(If the test target cannot `@testable import lmd_model_host` because it is an executable target, move `EmbeddingJobQueue.swift` into `Sources/SwiftLMHostProtocol/` instead and import that; the host already depends on it.)

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter EmbeddingJobQueueTests`
Expected: FAIL (type does not exist).

- [ ] **Step 3: Implement**

```swift
//
//  EmbeddingJobQueue.swift
//
//  Serializes embedding forwards with a two-lane wait queue. Priority waiters
//  resume before normal waiters; each lane is FIFO internally. With the lane
//  disabled every waiter joins the normal lane, giving strict FIFO. Depth and
//  wait metrics are emitted here so every consumer measures identically.
//

import Foundation
import SwiftLMMetrics

actor EmbeddingJobQueue {
  private let maxConcurrent: Int
  private let laneEnabled: Bool
  private var running = 0
  private var priorityWaiters: [CheckedContinuation<Void, Never>] = []
  private var normalWaiters: [CheckedContinuation<Void, Never>] = []

  init(maxConcurrent: Int, laneEnabled: Bool) {
    self.maxConcurrent = max(maxConcurrent, 1)
    self.laneEnabled = laneEnabled
  }

  var waitingCount: Int { priorityWaiters.count + normalWaiters.count }

  func acquire(priority: Bool) async {
    if running < maxConcurrent {
      running += 1
      publishDepth()
      return
    }
    let waitStarted = DispatchTime.now()
    await withCheckedContinuation { continuation in
      if priority && laneEnabled {
        priorityWaiters.append(continuation)
      } else {
        normalWaiters.append(continuation)
      }
      publishDepth()
    }
    let waitedSeconds =
      Double(DispatchTime.now().uptimeNanoseconds - waitStarted.uptimeNanoseconds)
      / 1_000_000_000
    SwiftLMMetrics.observeSeconds("lmd_embed_queue_wait_seconds", waitedSeconds)
  }

  func release() {
    if !priorityWaiters.isEmpty {
      let next = priorityWaiters.removeFirst()
      publishDepth()
      next.resume()
      return
    }
    if !normalWaiters.isEmpty {
      let next = normalWaiters.removeFirst()
      publishDepth()
      next.resume()
      return
    }
    running = max(running - 1, 0)
    publishDepth()
  }

  private func publishDepth() {
    SwiftLMMetrics.setGauge("lmd_embed_queue_depth", Double(waitingCount))
  }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter EmbeddingJobQueueTests`
Expected: PASS.

- [ ] **Step 5: Wire into EmbeddingHost**

`EmbeddingHost` stores `private let queue: EmbeddingJobQueue` built from its tuning (`maxConcurrent: tuning.maxConcurrentForwards, laneEnabled: tuning.priorityLaneEnabled`). In `framesInSpan(for:)`, after `inputs` parse and before the `backend.embed` call:

```swift
let realTokens = backend.countTokens(inputs: inputs)
let priority =
  inputs.count <= tuning.priorityMaxInputs || realTokens < tuning.priorityMaxTokens
await queue.acquire(priority: priority)
defer { Task { await queue.release() } }
```

(The `defer` must cover both the success and `embed failed` returns; place it immediately after acquire.)

- [ ] **Step 6: Build and test**

Run: `swift build && swift test --filter LMDModelHostTests`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add Sources/lmd-model-host/ Tests/LMDModelHostTests/
git commit -m "Queue embedding forwards through a two-lane priority queue in the host"
```

### Task 10: Router stops rejecting embeddings at the concurrency limit

**Files:**
- Modify: `Sources/SwiftLMRuntime/ModelRouter.swift` (`concurrencyLimit(for:)`)
- Test: locate the router test asserting embedding 429/`concurrencyLimitExceeded` via `search_code` ("embedding concurrency limit exceeded route test") and update it.

The router refuses an embedding request with HTTP 429 when the in-flight count reaches the concurrency limit. That refusal reaches clients as a hard failure: an lm-semantic-search indexing run on June 5 died on `capacity_exceeded ... limit reached (1)`. Task 9 moved the concurrency control into the host's queue, where excess requests wait instead of failing, so this task removes the router's refusal for embedding routes. Chat routes keep theirs.

- [ ] **Step 1: Change the limit**

```swift
private func concurrencyLimit(for kind: RouteKind) -> Int? {
  switch kind {
  case .chat:
    return chatMaxConcurrency
  case .embedding:
    // Forward concurrency is enforced by the embedding host's job queue
    // (EmbeddingJobQueue); admitting here and queueing there keeps bulk
    // clients from seeing 429s while a forward is busy.
    return nil
  case .video:
    return nil
  }
}
```

- [ ] **Step 2: Update tests**

Find and update any test that expects `RouteError.concurrencyLimitExceeded` for embedding routes: it should now expect successful routing. Keep the chat-limit tests untouched.

Run: `swift test --filter ModelRouter`
Expected: PASS.

- [ ] **Step 3: Commit**

```bash
git add Sources/SwiftLMRuntime/ModelRouter.swift Tests/
git commit -m "Stop rejecting embedding routes at the concurrency limit"
```

### Task 11: fp32 pooling

**Files:**
- Modify: `Sources/SwiftLMEmbed/NVEmbeddingBackend.swift` (`poolHiddenStates`)
- Test: `Tests/SwiftLMEmbedTests/NVEmbeddingBackendTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
func testPoolingPromotesBF16HiddenStatesToFloat32() throws {
  try withMLXMetallib {
    let hiddenStates = MLXArray([
      3.0 as Float, 4.0, 9.0, 12.0, 100.0, 100.0,
    ]).reshaped(1, 3, 2).asType(.bfloat16)
    let attentionMask = MLXArray([1 as Int32, 1, 0]).reshaped(1, 3)
    let pooled = NVEmbeddingBackend.poolHiddenStates(
      hiddenStates: hiddenStates,
      attentionMask: attentionMask,
      metadata: metadata(dimension: 2))
    pooled.eval()
    expect(pooled.dtype) == .float32
    assertVector(pooled[0].asArray(Float.self), approximately: [0.6, 0.8])
  }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter NVEmbeddingBackendTests/testPoolingPromotesBF16HiddenStatesToFloat32`
Expected: FAIL (`pooled.dtype` is `.bfloat16`).

- [ ] **Step 3: Implement**

First line of `poolHiddenStates` casts up, the rest operates on the cast value:

```swift
// Mean-pool and L2-normalize in fp32: the division and normalization are the
// most precision-sensitive steps, and the cast costs one elementwise pass.
let hiddenStates32 = hiddenStates.asType(.float32)
let mask = attentionMask.asType(.float32)
```

Replace subsequent uses of `hiddenStates` and `hiddenStates.dtype` with `hiddenStates32` and `.float32`.

- [ ] **Step 4: Run the embed suite**

Run: `swift test --filter SwiftLMEmbedTests`
Expected: PASS (existing pooling expectations unchanged: inputs were fp32, outputs still fp32).

- [ ] **Step 5: Commit**

```bash
git add Sources/SwiftLMEmbed/NVEmbeddingBackend.swift Tests/SwiftLMEmbedTests/NVEmbeddingBackendTests.swift
git commit -m "Pool and normalize NV embeddings in float32"
```

### Task 12: lmd bench embed

**Files:**
- Create: `Sources/lmd-bench/EmbedBenchStats.swift` (pure: corpus plus report math)
- Create: `Sources/lmd-bench/EmbedBenchRunner.swift` (HTTP driver)
- Create: `Sources/lmd/LMDBenchEmbedCommand.swift`
- Modify: `Sources/lmd/LMDBenchCommand.swift` (add subcommand)
- Modify: `Package.swift` (add `LMDBenchToolTests` test target if absent)
- Test: `Tests/LMDBenchToolTests/EmbedBenchStatsTests.swift`

- [ ] **Step 1: Write the failing stats tests**

```swift
import Nimble
import XCTest

@testable import LMDBenchTool

final class EmbedBenchStatsTests: XCTestCase {
  func testSyntheticCorpusIsDeterministicAndShaped() {
    let first = EmbedBenchStats.syntheticCorpus(count: 500, medianTokens: 93, seed: 42)
    let second = EmbedBenchStats.syntheticCorpus(count: 500, medianTokens: 93, seed: 42)
    expect(first) == second
    expect(first.count) == 500
    let estimated = first.map { ($0.utf8.count + 3) / 4 }.sorted()
    let median = estimated[250]
    expect(median).to(beCloseTo(93, within: 30))
    expect(estimated.last!) > 800  // long tail present
  }

  func testPercentileInterpolation() {
    let values: [Double] = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10]
    expect(EmbedBenchStats.percentile(values, 50)) == 5.5
    expect(EmbedBenchStats.percentile(values, 95)).to(beCloseTo(9.55, within: 0.01))
  }

  func testReportComputesTokensPerSecond() {
    let report = EmbedBenchStats.makeReport(
      batches: [
        EmbedBenchStats.BatchSample(rows: 32, estimatedTokens: 3_000, seconds: 3.0),
        EmbedBenchStats.BatchSample(rows: 32, estimatedTokens: 6_000, seconds: 3.0),
      ])
    expect(report.totalRows) == 64
    expect(report.estimatedTokensPerSecond).to(beCloseTo(1_500, within: 0.01))
    expect(report.latencyP50Seconds) == 3.0
  }
}
```

- [ ] **Step 2: Add the test target if missing and run**

If `Package.swift` has no `LMDBenchToolTests`, add a `.testTarget(name: "LMDBenchToolTests", dependencies: ["LMDBenchTool", "Nimble"])` beside the existing test targets.

Run: `swift test --filter EmbedBenchStatsTests`
Expected: FAIL (types do not exist).

- [ ] **Step 3: Implement EmbedBenchStats**

```swift
//
//  EmbedBenchStats.swift
//  LMDBenchTool
//
//  Pure corpus generation and report math for `lmd bench embed`. Deterministic
//  by seed so two runs on the same machine are comparable.
//

import Foundation

public enum EmbedBenchStats {
  public struct BatchSample: Sendable, Equatable {
    public let rows: Int
    public let estimatedTokens: Int
    public let seconds: Double
    public init(rows: Int, estimatedTokens: Int, seconds: Double) {
      self.rows = rows
      self.estimatedTokens = estimatedTokens
      self.seconds = seconds
    }
  }

  public struct Report: Sendable, Equatable {
    public let totalRows: Int
    public let totalEstimatedTokens: Int
    public let totalSeconds: Double
    public let estimatedTokensPerSecond: Double
    public let latencyP50Seconds: Double
    public let latencyP95Seconds: Double
  }

  /// Deterministic corpus shaped like the conversation chunk distribution:
  /// most entries near `medianTokens`, a long tail to roughly 12x the median.
  /// Token length is approximated as four bytes per token.
  public static func syntheticCorpus(count: Int, medianTokens: Int, seed: UInt64) -> [String] {
    var state = seed
    func nextRandom() -> UInt64 {
      // SplitMix64: deterministic, dependency-free.
      state &+= 0x9E37_79B9_7F4A_7C15
      var z = state
      z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
      z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
      return z ^ (z >> 31)
    }
    let word = "func "
    var corpus: [String] = []
    corpus.reserveCapacity(count)
    for _ in 0..<count {
      let roll = nextRandom() % 100
      let tokens: Int
      if roll < 70 {
        tokens = medianTokens / 2 + Int(nextRandom() % UInt64(medianTokens))
      } else if roll < 95 {
        tokens = medianTokens * 2 + Int(nextRandom() % UInt64(medianTokens * 4))
      } else {
        tokens = medianTokens * 8 + Int(nextRandom() % UInt64(medianTokens * 4))
      }
      let bytes = tokens * 4
      corpus.append(String(repeating: word, count: max(bytes / word.utf8.count, 1)))
    }
    return corpus
  }

  /// Linear-interpolated percentile over unsorted samples.
  public static func percentile(_ values: [Double], _ pct: Double) -> Double {
    precondition(!values.isEmpty)
    let sorted = values.sorted()
    let rank = (pct / 100.0) * Double(sorted.count - 1)
    let lower = Int(rank.rounded(.down))
    let upper = Int(rank.rounded(.up))
    if lower == upper {
      return sorted[lower]
    }
    let fraction = rank - Double(lower)
    return sorted[lower] + (sorted[upper] - sorted[lower]) * fraction
  }

  public static func makeReport(batches: [BatchSample]) -> Report {
    let totalRows = batches.reduce(0) { $0 + $1.rows }
    let totalTokens = batches.reduce(0) { $0 + $1.estimatedTokens }
    let totalSeconds = batches.reduce(0.0) { $0 + $1.seconds }
    let latencies = batches.map(\.seconds)
    return Report(
      totalRows: totalRows,
      totalEstimatedTokens: totalTokens,
      totalSeconds: totalSeconds,
      estimatedTokensPerSecond: totalSeconds > 0 ? Double(totalTokens) / totalSeconds : 0,
      latencyP50Seconds: percentile(latencies, 50),
      latencyP95Seconds: percentile(latencies, 95))
  }
}
```

- [ ] **Step 4: Run stats tests**

Run: `swift test --filter EmbedBenchStatsTests`
Expected: PASS. (Tune the synthetic distribution constants if the median assertion misses; the assertion has plus-or-minus 30 slack.)

- [ ] **Step 5: Implement the runner and CLI**

`EmbedBenchRunner.swift` is an async function that drives the live broker over HTTP. It takes a base URL, a model id, a corpus of strings, a rows-per-request count, and a request count. It slices the corpus into consecutive requests of `rowsPerRequest` inputs, cycling the corpus if it runs short. It POSTs each request to `{base}/v1/embeddings` with the body `{"model": model, "input": [..]}` via `URLSession` and times each one, collecting a `BatchSample` per request with estimated tokens at four bytes per token. After the loop it GETs `{base}/swiftlmd/metrics` and pulls out the histograms whose names start with `lmd_embed_` plus the two `lmd_embed_resolved_*` gauges, so the report shows server-side measurements next to client-side timings. It prints the `Report` as a human table, or as one JSON object when `--json` is set. Any non-200 response fails the run with a nonzero exit and the HTTP body printed.

`LMDBenchEmbedCommand.swift`:

```swift
struct LMDBenchEmbedCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "embed",
    abstract: "Benchmark the embedding path end to end over HTTP."
  )
  @Option(help: "Embedding model id.") var model: String = "nvidia/NV-EmbedCode-7b-v1"
  @Option(name: .customLong("base-url"), help: "Broker base URL.")
  var baseURL: String = "http://localhost:5400"
  @Option(help: "Corpus file, one input per line. Omit for synthetic.")
  var corpus: String?
  @Option(help: "Number of requests.") var requests: Int = 20
  @Option(name: .customLong("rows-per-request"), help: "Inputs per request.")
  var rowsPerRequest: Int = 64
  @Option(help: "Synthetic corpus median token length.") var medianTokens: Int = 93
  @Option(help: "Deterministic seed.") var seed: UInt64 = 42
  @Flag(help: "Emit the report as JSON.") var json = false

  func run() async throws {
    let texts: [String]
    if let corpus {
      texts = try String(contentsOfFile: corpus, encoding: .utf8)
        .split(separator: "\n").map(String.init)
    } else {
      texts = EmbedBenchStats.syntheticCorpus(
        count: requests * rowsPerRequest, medianTokens: medianTokens, seed: seed)
    }
    try await EmbedBenchRunner.run(
      baseURL: baseURL, model: model, corpus: texts,
      rowsPerRequest: rowsPerRequest, requests: requests, jsonOutput: json)
  }
}
```

Register in `LMDBenchCommand.subcommands`: `[LMDBenchRunCommand.self, LMDBenchEmbedCommand.self]`.

- [ ] **Step 6: Build and smoke-run against the live broker**

Run: `swift build && swift run lmd bench embed --requests 2 --rows-per-request 8`
Expected: a report with nonzero tokens/sec; server histograms listed.

- [ ] **Step 7: Commit**

```bash
git add Sources/lmd-bench/ Sources/lmd/LMDBenchCommand.swift Sources/lmd/LMDBenchEmbedCommand.swift Package.swift Tests/LMDBenchToolTests/
git commit -m "Add embed mode to lmd bench with synthetic corpus and server metrics readout"
```

### Task 13: Plists, configuration docs, key-conformance fixtures

**Files:**
- Modify: `deploy/io.goodkind.lmd.serve.plist.example`
- Modify: `deploy/io.goodkind.lmd.serve.test.plist.template`
- Modify: `docs/configuration.md`
- Modify: any key-conformance test fixtures (locate with `search_code`: "allCases plist example configuration docs conformance test")

- [ ] **Step 1: Update the example plist**

Add under `EnvironmentVariables` (and change the two existing values):

```xml
<key>LMD_EMBEDDING_MAX_CONCURRENCY</key><string>1</string>
<key>LMD_MLX_CACHE_LIMIT_GB</key><string></string>
<key>LMD_EMBED_BATCH_TOKEN_BUDGET</key><string></string>
<key>LMD_EMBED_BATCH_MAX_ROWS</key><string>256</string>
<key>LMD_EMBED_PRIORITY_MAX_INPUTS</key><string>2</string>
<key>LMD_EMBED_PRIORITY_MAX_TOKENS</key><string>2048</string>
<key>LMD_EMBED_PRIORITY_LANE</key><string>true</string>
```

Apply the same keys with the same literal values to the test template (no new placeholders, so `Tools/lmd-dev.swift` needs no change).

- [ ] **Step 2: Document the knobs**

Add a section to `docs/configuration.md` matching the spec's Configuration table: each key, its default, the auto semantics (blank means auto for budget and cache), and the FIFO escape hatch (`LMD_EMBED_PRIORITY_LANE=false`).

- [ ] **Step 3: Run the conformance and full suites**

Run: `make test`
Expected: PASS, including the BrokerConfig key-conformance check against the plist and docs.

- [ ] **Step 4: Commit**

```bash
git add deploy/ docs/configuration.md
git commit -m "Add embedding tuning knobs to plists and configuration docs"
```

### Task 14: Deploy and capture before and after bench runs

This task measures the speedup. The comparison needs a baseline binary that can report padding metrics but does not yet pack sub-batches, which is exactly the tree at the Task 5 commit, so the baseline run builds from that commit before the final deploy.

- [ ] **Step 1: Baseline**

```bash
git stash list  # ensure clean tree
git checkout <task-5-commit-sha>
make build && make install  # or the repo's deploy target
launchctl kickstart -k gui/$(id -u)/io.goodkind.lmd.serve
swift run lmd bench embed --requests 20 --rows-per-request 64 --json > /tmp/embed-bench-baseline.json
git checkout main
```

- [ ] **Step 2: Update the live plist and deploy the full branch**

Apply the Task 13 environment changes to `~/Library/LaunchAgents/io.goodkind.lmd.serve.plist`, then:

```bash
make build && make install
launchctl kickstart -k gui/$(id -u)/io.goodkind.lmd.serve
swift run lmd bench embed --requests 20 --rows-per-request 64 --json > /tmp/embed-bench-after.json
```

- [ ] **Step 3: Check exit criteria**

From the two JSON files and `/swiftlmd/metrics`:
- `lmd_embed_padding_ratio` p50 < 0.10 on the after run.
- After tokens/sec at least 5x baseline.
- During a bench run, a single `lmd embed -m nvidia/NV-EmbedCode-7b-v1 -t "priority probe"` completes in under 2 seconds.
- `embedding.tuning_resolved` appears in `log show --last 10m --predicate 'process == "lmd-serve"'` with the resolved values.

Record the numbers in the plan-execution notes. If a criterion fails, stop and diagnose before Phase 3.

- [ ] **Step 4: Commit any fixes and record the numbers**

```bash
git commit -am "Record embedding bench baseline and after numbers"  # if notes are kept in-repo
```

### Task 15: bf16 parity quality gate

**Files:**
- Create: `scripts/embed_parity.py` (lmd repo)
- Create: `scripts/embed_parity_queries.txt`

This gate proves the bf16 weights produce the same retrieval behavior as the fp32 originals. Both weight sets sit in the model catalog under their own ids: `nvidia/NV-EmbedCode-7b-v1` is the bf16 set and `nvidia/NV-EmbedCode-7b-v1-fp32` is the original. The script embeds the same texts through both ids over HTTP, so no files move during the gate.

- [ ] **Step 1: Write the script**

uv single-file script (PEP 723 header: `httpx`, `numpy`). Behavior:

1. Inputs: `--base-url http://localhost:5400`, `--model-a nvidia/NV-EmbedCode-7b-v1`, `--model-b nvidia/NV-EmbedCode-7b-v1-fp32`, `--chunks-file` (a text file with one document per line, or a directory of lm-semantic-search chunk caches to sample), `--queries-file`, `--batch-rows 32`, `--seed 42`.
2. When `--chunks-file` is a directory, sample 1,000 `content` fields deterministically from the `*.json` chunk caches inside it.
3. Embed every chunk and query with both models (batched requests).
4. Report: median and p1 pairwise cosine between model-a and model-b vectors for the same text; for each query, the top-10 nearest chunks by cosine under each model and the mean top-10 overlap fraction.
5. Pass/fail: median cosine at or above 0.999 AND mean top-10 overlap at or above 0.98 exits 0; anything else exits 1 with the numbers printed.

Hand-write 50 real search queries into `scripts/embed_parity_queries.txt` covering code and conversation lookups.

- [ ] **Step 2: Run the gate**

```bash
uv run scripts/embed_parity.py --chunks-file ~/.local/state/lm-semantic-search/chunks --queries-file scripts/embed_parity_queries.txt
```

Expected: exit 0. The fp32 host loads (~27GB) beside the bf16 host (~13GB); run on AC power. On failure: record the numbers, then the rollback is swapping the two model directory names back and re-running ingests from the bf16 period.

- [ ] **Step 3: Commit**

```bash
git add scripts/embed_parity.py scripts/embed_parity_queries.txt
git commit -m "Add bf16 versus fp32 embedding parity gate script"
```

---

## Phase 3: lm-semantic-search (repo: /Users/agoodkind/Sites/lm-semantic-search)

### Task 16: Token-estimate packer

**Files:**
- Create: `internal/semantic/batching.go`
- Test: `internal/semantic/batching_test.go`

- [ ] **Step 1: Write the failing tests**

```go
package semantic

import (
	"strings"
	"testing"

	"goodkind.io/lm-semantic-search/internal/model"
)

func chunkOfBytes(n int) model.StoredChunk {
	return model.StoredChunk{Content: strings.Repeat("a", n)}
}

func TestPackChunksEmptyInputYieldsNoGroups(t *testing.T) {
	groups := packChunksByEstimatedTokens(nil, 32, 6000)
	if len(groups) != 0 {
		t.Fatalf("groups = %d, want 0", len(groups))
	}
}

func TestPackChunksSingleOversizeChunkShipsAlone(t *testing.T) {
	chunks := []model.StoredChunk{chunkOfBytes(100_000), chunkOfBytes(4)}
	groups := packChunksByEstimatedTokens(chunks, 32, 6000)
	if len(groups) != 2 {
		t.Fatalf("groups = %d, want 2", len(groups))
	}
	if len(groups[0]) != 1 {
		t.Fatalf("first group rows = %d, want 1 (oversize ships alone)", len(groups[0]))
	}
}

func TestPackChunksClosesOnTokenBudget(t *testing.T) {
	// 10 chunks of 400 bytes = 100 estimated tokens each; budget 250 packs 2 per group.
	chunks := make([]model.StoredChunk, 10)
	for i := range chunks {
		chunks[i] = chunkOfBytes(400)
	}
	groups := packChunksByEstimatedTokens(chunks, 32, 250)
	if len(groups) != 5 {
		t.Fatalf("groups = %d, want 5", len(groups))
	}
}

func TestPackChunksClosesOnRowCap(t *testing.T) {
	chunks := make([]model.StoredChunk, 10)
	for i := range chunks {
		chunks[i] = chunkOfBytes(4)
	}
	groups := packChunksByEstimatedTokens(chunks, 4, 6000)
	want := []int{4, 4, 2}
	if len(groups) != len(want) {
		t.Fatalf("groups = %d, want %d", len(groups), len(want))
	}
	for i, group := range groups {
		if len(group) != want[i] {
			t.Fatalf("group %d rows = %d, want %d", i, len(group), want[i])
		}
	}
}

func TestPackChunksPreservesOrderAndCoverage(t *testing.T) {
	chunks := make([]model.StoredChunk, 25)
	for i := range chunks {
		chunks[i] = chunkOfBytes((i*53)%900 + 1)
	}
	groups := packChunksByEstimatedTokens(chunks, 8, 300)
	var flattened []model.StoredChunk
	for _, group := range groups {
		flattened = append(flattened, group...)
	}
	if len(flattened) != len(chunks) {
		t.Fatalf("flattened = %d chunks, want %d", len(flattened), len(chunks))
	}
	for i := range chunks {
		if flattened[i].Content != chunks[i].Content {
			t.Fatalf("chunk %d out of order", i)
		}
	}
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `go test ./internal/semantic/ -run TestPackChunks -v`
Expected: FAIL (function undefined).

- [ ] **Step 3: Implement**

```go
package semantic

import "goodkind.io/lm-semantic-search/internal/model"

// estimatedTokenCount approximates the embedding server's tokenizer count at
// four bytes per token with a floor of one. The server enforces exact counts;
// this estimate only shapes request granularity.
func estimatedTokenCount(content string) int {
	count := (len(content) + 3) / 4
	if count < 1 {
		return 1
	}
	return count
}

// packChunksByEstimatedTokens groups consecutive chunks for one embedding
// request. A group closes when adding the next chunk would push the estimated
// token sum past tokenBudget or the row count past maxRows. A single chunk
// above the budget ships alone. Order is preserved and every chunk lands in
// exactly one group.
func packChunksByEstimatedTokens(
	chunks []model.StoredChunk,
	maxRows int,
	tokenBudget int,
) [][]model.StoredChunk {
	if maxRows < 1 {
		maxRows = 1
	}
	if tokenBudget < 1 {
		tokenBudget = 1
	}
	groups := make([][]model.StoredChunk, 0)
	current := make([]model.StoredChunk, 0, maxRows)
	currentTokens := 0
	for _, chunk := range chunks {
		tokens := estimatedTokenCount(chunk.Content)
		overBudget := currentTokens+tokens > tokenBudget
		overRows := len(current)+1 > maxRows
		if len(current) > 0 && (overBudget || overRows) {
			groups = append(groups, current)
			current = make([]model.StoredChunk, 0, maxRows)
			currentTokens = 0
		}
		current = append(current, chunk)
		currentTokens += tokens
	}
	if len(current) > 0 {
		groups = append(groups, current)
	}
	return groups
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `go test ./internal/semantic/ -run TestPackChunks -v`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add internal/semantic/batching.go internal/semantic/batching_test.go
git commit -m "Add token-estimate chunk packer to semantic package"
```

### Task 17: Config knobs in lm-semantic-search

**Files:**
- Modify: `internal/config/config.go`
- Test: the package's existing config test file (locate with `search_code`: "config Default test persisted embeddingBatchSize")

- [ ] **Step 1: Write the failing tests**

In the config test file:

```go
func TestEmbeddingBatchTokenBudgetDefaultsTo6000(t *testing.T) {
	cfg := configFromPersisted(t, persistedConfig{})
	if cfg.EmbeddingBatchTokenBudget != 6000 {
		t.Fatalf("EmbeddingBatchTokenBudget = %d, want 6000", cfg.EmbeddingBatchTokenBudget)
	}
}

func TestQueryInstructionPrefixDefaultsForNVEmbedCode(t *testing.T) {
	cfg := configFromPersisted(t, persistedConfig{EmbeddingModel: "nvidia/NV-EmbedCode-7b-v1"})
	want := "Instruct: Retrieve code or text relevant to the query.\nQuery: "
	if cfg.QueryInstructionPrefix != want {
		t.Fatalf("QueryInstructionPrefix = %q, want %q", cfg.QueryInstructionPrefix, want)
	}
}

func TestQueryInstructionPrefixEmptyForOtherModels(t *testing.T) {
	cfg := configFromPersisted(t, persistedConfig{EmbeddingModel: "Snowflake/snowflake-arctic-embed-l-v2.0"})
	if cfg.QueryInstructionPrefix != "" {
		t.Fatalf("QueryInstructionPrefix = %q, want empty", cfg.QueryInstructionPrefix)
	}
}
```

(`configFromPersisted` is a test helper: write the persisted JSON to a temp `CLAUDE_CONTEXTD_CONFIG_ROOT`, call `config.Default()`, return the result. If the test file already has an equivalent helper, use it.)

- [ ] **Step 2: Run tests to verify they fail**

Run: `go test ./internal/config/ -run 'TestEmbeddingBatchTokenBudget|TestQueryInstructionPrefix' -v`
Expected: FAIL.

- [ ] **Step 3: Implement**

In `config.go`:

```go
// In Config:
// EmbeddingBatchTokenBudget caps the estimated tokens (bytes/4) packed into
// one embedding request. EmbeddingBatchSize stays as the row-count ceiling.
EmbeddingBatchTokenBudget int
// QueryInstructionPrefix is prepended to query-time embedding text only.
// Stored document vectors are embedded bare and stay valid.
QueryInstructionPrefix string

// In persistedConfig:
EmbeddingBatchTokenBudget int    `json:"embeddingBatchTokenBudget"`
QueryInstructionPrefix    string `json:"queryInstructionPrefix"`
```

In `Default()` after the model resolution:

```go
const defaultEmbeddingBatchTokenBudget = 6000
const nvEmbedCodeQueryPrefix = "Instruct: Retrieve code or text relevant to the query.\nQuery: "

batchTokenBudget := fileConfig.EmbeddingBatchTokenBudget
if batchTokenBudget <= 0 {
	batchTokenBudget = defaultEmbeddingBatchTokenBudget
}
queryPrefix := fileConfig.QueryInstructionPrefix
if queryPrefix == "" && strings.Contains(defaultModel, "NV-EmbedCode") {
	queryPrefix = nvEmbedCodeQueryPrefix
}
```

Assign both into the returned `Config`.

- [ ] **Step 4: Run tests to verify they pass**

Run: `go test ./internal/config/ -v`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add internal/config/
git commit -m "Add embeddingBatchTokenBudget and queryInstructionPrefix config fields"
```

### Task 18: Wire the packer into insertChunksBatched

**Files:**
- Modify: `internal/semantic/staging.go` (`insertChunksBatched`)
- Test: existing staging and conversation tests plus one new test

- [ ] **Step 1: Write the failing test**

In `internal/semantic/batching_test.go` (or the existing staging test file if it has a fake embedder):

```go
func TestInsertChunksBatchedRespectsTokenBudget(t *testing.T) {
	// A fake embedder that records the size of each EmbedBatch call.
	// Use the package's existing embedder fake; if none exists, define one
	// implementing embedding.Provider with Embed and EmbedBatch.
	recorded := [][]int{}
	service := newServiceWithFakeEmbedder(t, func(texts []string) {
		recorded = append(recorded, []int{len(texts)})
	})
	service.cfg.EmbeddingBatchSize = 32
	service.cfg.EmbeddingBatchTokenBudget = 250
	chunks := make([]model.StoredChunk, 10)
	for i := range chunks {
		chunks[i] = chunkOfBytes(400) // 100 estimated tokens each
	}
	err := service.insertChunksBatched(
		context.Background(), "test_collection", chunks, true, "test", nil, nil)
	if err != nil {
		t.Fatalf("insertChunksBatched: %v", err)
	}
	if len(recorded) != 5 {
		t.Fatalf("embed calls = %d, want 5 (2 chunks per 250-token budget)", len(recorded))
	}
}
```

Adapt the test construction to the seams the semantic package actually has. The insert step needs a fake Milvus client, so follow whatever the existing semantic package tests use for that. If the package has no service-level fakes at all, extract the pack call into its own method and assert that method's output for the same config instead.

- [ ] **Step 2: Run to verify it fails, then implement**

Replace the fixed slicing in `insertChunksBatched`:

```go
batchRows := service.cfg.EmbeddingBatchSize
if batchRows <= 0 {
	batchRows = 32
}
tokenBudget := service.cfg.EmbeddingBatchTokenBudget
if tokenBudget <= 0 {
	tokenBudget = 6000
}
packs := packChunksByEstimatedTokens(chunks, batchRows, tokenBudget)
totalBatches := len(packs)
var writtenRows int32
var reusedRows int32
var embeddedRows int32

for batchIndex, chunkBatch := range packs {
	vectors, reused, err := service.embedChunkBatch(ctx, chunkBatch, reuse)
	// ... existing body unchanged from here (collection create, insertBatch,
	// counters, progress callback using batchIndex+1 and totalBatches) ...
}
```

- [ ] **Step 3: Run the package tests**

Run: `go test ./internal/semantic/ -v`
Expected: PASS, including pre-existing tests (update any that assert 32-row slicing).

- [ ] **Step 4: Commit**

```bash
git add internal/semantic/
git commit -m "Pack embedding requests by estimated token budget in insertChunksBatched"
```

### Task 19: Query instruction prefix at the search choke point

**Files:**
- Modify: `internal/semantic/service.go` (`searchCollection`)
- Test: `internal/semantic/query_prefix_test.go`

- [ ] **Step 1: Write the failing test**

```go
package semantic

import (
	"testing"

	"goodkind.io/lm-semantic-search/internal/config"
)

func TestQueryTextForEmbeddingAppliesConfiguredPrefix(t *testing.T) {
	service := &Service{cfg: config.Config{
		QueryInstructionPrefix: "Instruct: task.\nQuery: ",
	}}
	got := service.queryTextForEmbedding("find the retry loop")
	want := "Instruct: task.\nQuery: find the retry loop"
	if got != want {
		t.Fatalf("queryTextForEmbedding = %q, want %q", got, want)
	}
}

func TestQueryTextForEmbeddingNoPrefixPassesThrough(t *testing.T) {
	service := &Service{cfg: config.Config{}}
	if got := service.queryTextForEmbedding("q"); got != "q" {
		t.Fatalf("queryTextForEmbedding = %q, want %q", got, "q")
	}
}
```

- [ ] **Step 2: Run to verify it fails, then implement**

```go
// queryTextForEmbedding applies the configured query instruction prefix to
// the dense query embed. The sparse (BM25) leg keeps the raw query text, and
// stored document vectors are never prefixed, so the index stays valid.
func (service *Service) queryTextForEmbedding(query string) string {
	prefix := service.cfg.QueryInstructionPrefix
	if prefix == "" {
		return query
	}
	return prefix + query
}
```

In `searchCollection`, change the embed line only:

```go
queryVector, err := service.embedder.Embed(ctx, service.queryTextForEmbedding(query))
```

The sparse request (`entity.Text(query)`) and all filters keep the raw query.

- [ ] **Step 3: Run package tests, then the repo gates**

Run: `go test ./internal/semantic/ -v && make test && make lint`
Expected: PASS.

- [ ] **Step 4: Commit**

```bash
git add internal/semantic/
git commit -m "Apply query instruction prefix to dense query embedding"
```

---

## Final task: end-to-end acceptance

### Task 20: Acceptance run

- [ ] **Step 1: Deploy both sides**

lmd: `make build && make install && launchctl kickstart -k gui/$(id -u)/io.goodkind.lmd.serve`.
lm-semantic-search: build and install per its Makefile, set `embeddingBatchSize: 256` and confirm the new fields in `~/.config/lm-semantic-search/config.json`, then `launchctl kickstart -k gui/$(id -u)/io.goodkind.lm-semantic-search-daemon`.

- [ ] **Step 2: Trigger a real ingest and measure**

Force a sync of a sizable codebase (or wait for the conversation ingest cycle). While it runs, capture:

- `/swiftlmd/metrics`: `lmd_embed_padding_ratio` p50 < 0.10.
- `macmon pipe -s 20`: GPU utilization > 70% sustained during embed windows.
- Bench comparison: after-numbers at least 10x the fp32 count-32 baseline tokens/sec (baseline from Task 14).
- `time lmd embed -m nvidia/NV-EmbedCode-7b-v1 -t "acceptance probe"` during the ingest: under 2 seconds.
- Host trace `mlx_peak` < 30 GB, and `sysctl vm.swapusage` shows no growth across the run.

- [ ] **Step 3: Retrieval spot check**

Run 20 known-answer queries through `search_code` (10 code, 10 conversation) and confirm the expected files and conversations still appear top-3. The prefix change may improve placement; any regression fails the gate.

- [ ] **Step 4: Record results and close out**

Write the measured numbers into `docs/superpowers/specs/2026-06-10-embedding-perf-design.md` under a new "Measured outcomes" section, commit, and report.

---

## Self-review notes

Spec coverage, by spec section:

- Configuration knobs: Tasks 1, 13, and 17.
- Auto-sizing and spawn logging: Tasks 2 and 3.
- Phase 0 metrics: Tasks 4 and 5. The queue metrics arrive with the queue itself in Task 9.
- Bench mode: Task 12. Config defaults and deploy: Tasks 13 and 14.
- Phase 1 packing: Tasks 6 and 7. Priority lane: Tasks 8 and 9.
- Router admission: Task 10. This is a documented deviation from the spec's wording: the spec keeps the limit at admission, but rejecting at admission breaks bulk clients with 429s, so the limit moved into the host queue where requests wait instead.
- Phase 2 remaining work: Task 11 (fp32 pooling) and Task 15 (parity gate). The weight conversion itself is complete.
- Phase 3: Tasks 16 through 19. End-to-end acceptance: Task 20.

Judgment calls the executor resolves on site, each with its fallback named in the task: the exact field name of the memory probe reading (Task 3), whether `SnapshotSink.makeRecorder` already aggregates histograms (Task 4), which test seams the semantic package offers (Task 18), and whether `EmbeddingJobQueue` must live in `SwiftLMHostProtocol` to be importable from tests (Task 9).
