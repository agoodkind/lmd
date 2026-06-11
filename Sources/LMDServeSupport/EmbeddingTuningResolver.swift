//
//  EmbeddingTuningResolver.swift
//  LMDServeSupport
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-06-10.
//  Copyright © 2026, all rights reserved.
//
//  Resolves the embedding host's tuning values. Explicit configuration always
//  wins; auto values derive from free unified memory and a worst-case
//  per-slot transient estimate. The cache cap resolves first, then the slot
//  budget fits inside it (spec: docs/superpowers/specs/2026-06-10-embedding-perf-design.md).
//

import Foundation

// MARK: - EmbeddingHostTuning

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
    cacheLimitBytes: Int,
    slotBudget: Int,
    maxRows: Int,
    priorityMaxInputs: Int,
    priorityMaxTokens: Int,
    priorityLaneEnabled: Bool,
    maxConcurrentForwards: Int
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

// MARK: - EmbeddingTuningResolver

public enum EmbeddingTuningResolver {
  static let gibibyte: Int64 = 1_073_741_824
  /// The auto cache cap clamps to this band, in GiB.
  static let minCacheGiB = 2
  static let maxCacheGiB = 16
  /// The auto slot budget clamps to this band and rounds to this granularity.
  static let minSlotBudget = 2_048
  static let maxSlotBudget = 32_768
  static let slotBudgetGranularity = 1_024
  /// The auto cache cap targets this fraction of free memory (one eighth).
  static let autoCacheFreeMemoryDivisor = 8.0
  /// The auto slot budget reserves this headroom multiple over the worst-case
  /// transient estimate, so a mis-estimate does not immediately thrash.
  static let transientHeadroomFactor = 2
  /// Activation copies one padded slot holds live during a forward: the
  /// gate/up/SiLU/down MLP intermediates, and the residual, norm, QKV, and
  /// attention-output buffers at hidden width.
  static let mlpActivationsPerSlot = 4
  static let hiddenActivationsPerSlot = 8
  /// NV-EmbedCode-7b-v1 dimensions (config.json: hidden 4096, intermediate
  /// 14336) at bf16. A different embedding model is tuned via the explicit
  /// knobs rather than new constants here.
  public static let defaultHiddenSize = 4_096
  public static let defaultIntermediateSize = 14_336
  public static let defaultDtypeBytes = 2

  /// Worst-case live transient bytes one padded slot contributes to a forward,
  /// at the loaded dtype width.
  public static func transientBytesPerSlot(
    hiddenSize: Int,
    intermediateSize: Int,
    dtypeBytes: Int
  ) -> Int {
    dtypeBytes
      * (mlpActivationsPerSlot * intermediateSize + hiddenActivationsPerSlot * hiddenSize)
  }

  /// Explicit GB wins. Auto: the largest power-of-two GiB at or under one
  /// eighth of free memory, clamped to the 2 GiB to 16 GiB band.
  public static func resolveCacheLimitBytes(explicitGB: Double?, freeMemoryBytes: Int64) -> Int {
    if let explicitGB {
      return Int(explicitGB * Double(gibibyte))
    }
    let targetGiB = Double(freeMemoryBytes) / autoCacheFreeMemoryDivisor / Double(gibibyte)
    let clampedGiB = min(max(targetGiB, Double(minCacheGiB)), Double(maxCacheGiB))
    let chosenGiB = 1 << Int(log2(clampedGiB))
    return chosenGiB * Int(gibibyte)
  }

  /// Explicit wins. Auto: the largest budget whose worst-case transients,
  /// with headroom, fit inside the cache cap; rounded down to the granularity
  /// and clamped to the budget band.
  public static func resolveSlotBudget(
    explicit: Int?,
    cacheLimitBytes: Int,
    transientBytesPerSlot: Int
  ) -> Int {
    if let explicit {
      return explicit
    }
    let bytesPerSlot = max(transientBytesPerSlot, 1)
    let raw = cacheLimitBytes / (transientHeadroomFactor * bytesPerSlot)
    let rounded = (raw / slotBudgetGranularity) * slotBudgetGranularity
    return min(max(rounded, minSlotBudget), maxSlotBudget)
  }
}
