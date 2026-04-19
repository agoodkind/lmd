//
//  MemoryBudget.swift
//  SwiftLMRuntime
//
//  Created by Alex Goodkind <alex@goodkind.io> on 2026-04-18.
//  Copyright © 2026
//

import AppLogger
import Foundation

private let log = AppLogger.logger(category: "MemoryBudget")

// MARK: - Memory budget

/// Simple memory budget for the SwiftLM daemon.
///
/// Answers whether more bytes can fit without evicting something. The
/// budget is fixed at configuration time. The daemon keeps a virtual
/// accounting of what it has spawned, which is cheaper and deterministic
/// for routing decisions than querying the live system.
public struct MemoryBudget: Sendable, Equatable {
  /// Hard ceiling in bytes we will allocate to SwiftLM instances in total.
  public let ceilingBytes: Int64
  /// Bytes reserved for other applications and system overhead.
  public let reservedBytes: Int64

  public init(ceilingBytes: Int64, reservedBytes: Int64 = 0) {
    self.ceilingBytes = ceilingBytes
    self.reservedBytes = reservedBytes
  }

  /// Total bytes the daemon may spend on loaded models.
  public var usable: Int64 { max(0, ceilingBytes - reservedBytes) }

  /// True when `allocated + newBytes <= usable`.
  public func canAccommodate(currentlyAllocated: Int64, needing newBytes: Int64) -> Bool {
    currentlyAllocated + newBytes <= usable
  }

  /// Convenience: how many bytes must be freed to fit `needing`.
  public func overCommitmentIfAdding(currentlyAllocated: Int64, needing newBytes: Int64) -> Int64 {
    max(0, (currentlyAllocated + newBytes) - usable)
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

  public init(
    modelID: String,
    sizeBytes: Int64,
    lastUsed: Date,
    inFlightRequests: Int,
    isEmbedding: Bool = false
  ) {
    self.modelID = modelID
    self.sizeBytes = sizeBytes
    self.lastUsed = lastUsed
    self.inFlightRequests = inFlightRequests
    self.isEmbedding = isEmbedding
  }

  public var isIdle: Bool { inFlightRequests == 0 }
}

/// Pure functions for eviction decisions. No state, no IO, fully tested.
public enum EvictionPolicy {
  /// Pick models to evict until there is room to fit `needing`. Returns an
  /// empty array if no combination works.
  ///
  /// - Parameters:
  ///   - candidates: Every currently loaded model. Busy models (in-flight
  ///     requests > 0) are never evicted.
  ///   - needing: Bytes the new model needs.
  ///   - budget: Memory budget.
  ///   - currentlyAllocated: Bytes currently spent on loaded models.
  /// - Returns: Model IDs to unload in order. May be empty if no plan fits.
  public static func planEviction(
    candidates: [EvictionCandidate],
    needing newBytes: Int64,
    budget: MemoryBudget,
    currentlyAllocated: Int64
  ) -> [String] {
    if budget.canAccommodate(currentlyAllocated: currentlyAllocated, needing: newBytes) {
      return []
    }
    // Only consider idle models. Evict chat models before embedding models.
    // Within each group, evict oldest idle first.
    let idle = candidates.filter { $0.isIdle }.sorted { a, b in
      let pa = a.isEmbedding ? 1 : 0
      let pb = b.isEmbedding ? 1 : 0
      if pa != pb {
        return pa < pb
      }
      return a.lastUsed < b.lastUsed
    }
    var allocated = currentlyAllocated
    var toEvict: [String] = []
    for c in idle {
      allocated -= c.sizeBytes
      toEvict.append(c.modelID)
      if budget.canAccommodate(currentlyAllocated: allocated, needing: newBytes) {
        return toEvict
      }
    }
    // Could not free enough.
    return []
  }
}
