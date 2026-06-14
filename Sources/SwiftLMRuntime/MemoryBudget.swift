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
  /// Whether the model is routed to embeddings. Embedding models default to the
  /// low priority tier, so they are evicted and preempted before chat or video.
  public let isEmbedding: Bool
  /// Resolved eviction priority. Lower values are reclaimed first, and a load
  /// can only preempt a busy model whose priority is strictly lower than its own.
  public let priority: Int
  /// When true, the model is exempt from every eviction path.
  public let pinned: Bool
  public let loadConfig: ModelLoadConfig

  public init(
    modelID: String,
    sizeBytes: Int64,
    lastUsed: Date,
    inFlightRequests: Int,
    isEmbedding: Bool = false,
    priority: Int? = nil,
    pinned: Bool = false,
    loadConfig: ModelLoadConfig = .default
  ) {
    self.modelID = modelID
    self.sizeBytes = sizeBytes
    self.lastUsed = lastUsed
    self.inFlightRequests = inFlightRequests
    self.isEmbedding = isEmbedding
    self.priority = priority ?? (isEmbedding ? LoadPriority.low : LoadPriority.high)
    self.pinned = pinned
    self.loadConfig = loadConfig
  }

  public var isIdle: Bool { inFlightRequests == 0 }
}

// MARK: - EvictionPlan

/// The models a load may reclaim, split by how they are reclaimed. Idle victims
/// are unloaded immediately; busy victims are drained and then preempted.
public struct EvictionPlan: Sendable, Equatable {
  /// Idle victims to unload immediately, in unload order.
  public let idle: [String]
  /// Busy lower-priority victims to drain then preempt, in unload order.
  public let busy: [String]

  public init(idle: [String], busy: [String]) {
    self.idle = idle
    self.busy = busy
  }

  public var isEmpty: Bool {
    idle.isEmpty && busy.isEmpty
  }

  /// Every victim, idle first then busy, in unload order.
  public var all: [String] {
    idle + busy
  }
}

/// Pure functions for eviction decisions. No state, no IO, fully tested.
public enum EvictionPolicy {
  /// Plan which loaded models to reclaim so a load requested at
  /// `requestorPriority` can free `bytesToFree`.
  ///
  /// Pinned models are never chosen. Idle models at or below the requestor's
  /// priority are reclaimed first, lowest priority then least-recently-used.
  /// When idle models cannot reach the target, busy models whose priority is
  /// strictly lower than the requestor's are added as drain-and-preempt victims,
  /// in the same order. Equal-priority busy peers are never preempted.
  ///
  /// When even every eligible model cannot reach `bytesToFree`, all of them are
  /// returned so the caller can reclaim them and re-measure live memory.
  ///
  /// - Parameters:
  ///   - candidates: Every currently loaded model.
  ///   - bytesToFree: Target number of bytes to reclaim.
  ///   - requestorPriority: Priority of the load asking for room. Defaults to
  ///     the maximum so background pressure relief can reclaim any idle model.
  /// - Returns: Idle and busy victims to reclaim. Empty when nothing needs freeing.
  public static func planEvictionToFree(
    candidates: [EvictionCandidate],
    bytesToFree: Int64,
    requestorPriority: Int = .max
  ) -> EvictionPlan {
    if bytesToFree <= 0 {
      return EvictionPlan(idle: [], busy: [])
    }
    let idleEligible =
      candidates
      .filter { !$0.pinned && $0.isIdle && $0.priority <= requestorPriority }
      .sorted(by: evictionOrder)
    let busyEligible =
      candidates
      .filter { !$0.pinned && !$0.isIdle && $0.priority < requestorPriority }
      .sorted(by: evictionOrder)

    var freed: Int64 = 0
    var idle: [String] = []
    for candidate in idleEligible {
      freed += candidate.sizeBytes
      idle.append(candidate.modelID)
      if freed >= bytesToFree {
        return EvictionPlan(idle: idle, busy: [])
      }
    }
    var busy: [String] = []
    for candidate in busyEligible {
      freed += candidate.sizeBytes
      busy.append(candidate.modelID)
      if freed >= bytesToFree {
        return EvictionPlan(idle: idle, busy: busy)
      }
    }
    return EvictionPlan(idle: idle, busy: busy)
  }

  /// Reclaim order: lowest priority first, then least-recently-used.
  private static func evictionOrder(_ lhs: EvictionCandidate, _ rhs: EvictionCandidate) -> Bool {
    if lhs.priority != rhs.priority {
      return lhs.priority < rhs.priority
    }
    return lhs.lastUsed < rhs.lastUsed
  }
}
