//
//  MemoryBudget.swift
//  SwiftLMRuntime
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-04-18.
//  Copyright © 2026, all rights reserved.
//

import Foundation

// MARK: - Live memory reading

/// A point-in-time view of system memory used for load admission.
///
/// The router never reads the system directly. It receives one of these
/// through an injected ``MemoryProbe`` so the admission logic stays pure and
/// testable. The broker supplies a real probe backed by `host_statistics64`
/// and the system memory-pressure source.
public struct MemoryReading: Sendable, Equatable {
  /// Bytes the system can hand to a new allocation without swapping or
  /// compressing memory that is in active use.
  public let availableBytes: Int64
  /// True when the OS reports memory pressure at warning or critical level.
  public let underPressure: Bool

  public init(availableBytes: Int64, underPressure: Bool) {
    self.availableBytes = availableBytes
    self.underPressure = underPressure
  }
}

/// Pulls the current memory reading on demand. The broker supplies a real
/// probe backed by the live system; tests supply a controllable fake.
public typealias MemoryProbe = @Sendable () -> MemoryReading

// MARK: - Headroom policy

/// Pure headroom math. No state, no IO, fully tested.
public enum HeadroomPolicy {
  /// Bytes that must be freed so that, after loading `needing`, at least
  /// `reserveBytes` of memory remains available. Zero when already satisfied.
  public static func bytesToFree(
    availableBytes: Int64,
    needing: Int64,
    reserveBytes: Int64
  ) -> Int64 {
    max(0, reserveBytes + needing - availableBytes)
  }
}

// MARK: - Eviction

/// Candidate for eviction. The ModelRouter builds one of these per loaded model.
public struct EvictionCandidate: Sendable, Equatable {
  public let modelID: String
  public let sizeBytes: Int64
  public let lastUsed: Date
  /// True while a request is being actively served by this model.
  public let inFlightRequests: Int
  /// When true, eviction planning deprioritizes this model (chat evicts first).
  public let isEmbedding: Bool
  public let loadConfig: ModelLoadConfig

  public init(
    modelID: String,
    sizeBytes: Int64,
    lastUsed: Date,
    inFlightRequests: Int,
    isEmbedding: Bool = false,
    loadConfig: ModelLoadConfig = .default
  ) {
    self.modelID = modelID
    self.sizeBytes = sizeBytes
    self.lastUsed = lastUsed
    self.inFlightRequests = inFlightRequests
    self.isEmbedding = isEmbedding
    self.loadConfig = loadConfig
  }

  public var isIdle: Bool { inFlightRequests == 0 }
}

/// Pure functions for eviction decisions. No state, no IO, fully tested.
public enum EvictionPolicy {
  /// Pick idle models to unload until their combined size reaches
  /// `bytesToFree`, returning their ids in unload order.
  ///
  /// Busy models (in-flight requests > 0) are never chosen. Chat models are
  /// chosen before embedding models, and within each group the least recently
  /// used is chosen first.
  ///
  /// When the idle models cannot reach `bytesToFree`, every idle model is
  /// returned so the caller can unload them all and then re-measure live
  /// memory to decide whether the load is admitted.
  ///
  /// - Parameters:
  ///   - candidates: Every currently loaded model.
  ///   - bytesToFree: Target number of bytes to reclaim.
  /// - Returns: Model ids to unload in order. Empty when nothing needs freeing.
  public static func planEvictionToFree(
    candidates: [EvictionCandidate],
    bytesToFree: Int64
  ) -> [String] {
    if bytesToFree <= 0 {
      return []
    }
    let idle = candidates.filter(\.isIdle).sorted { a, b in
      let pa = a.isEmbedding ? 1 : 0
      let pb = b.isEmbedding ? 1 : 0
      if pa != pb {
        return pa < pb
      }
      return a.lastUsed < b.lastUsed
    }
    var freed: Int64 = 0
    var toEvict: [String] = []
    for c in idle {
      freed += c.sizeBytes
      toEvict.append(c.modelID)
      if freed >= bytesToFree {
        return toEvict
      }
    }
    return toEvict
  }
}
