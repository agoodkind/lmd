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
