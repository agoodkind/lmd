//
//  MemoryBudgetTests.swift
//  SwiftLMRuntimeTests
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-04-18.
//  Copyright © 2026, all rights reserved.
//

import Nimble
import XCTest

@testable import SwiftLMRuntime

final class HeadroomPolicyTests: XCTestCase {
  private let gb: Int64 = 1_073_741_824

  func testNoFreeNeededWhenReserveHolds() {
    // 100 available, load needs 40, keep 20 free -> 60 remains, nothing to free.
    let free = HeadroomPolicy.bytesToFree(
      availableBytes: 100 * gb, needing: 40 * gb, reserveBytes: 20 * gb)
    expect(free) == 0
  }

  func testFreeNeededWhenLoadWouldBreachReserve() {
    // 50 available, load needs 40, keep 20 free -> short by 10.
    let free = HeadroomPolicy.bytesToFree(
      availableBytes: 50 * gb, needing: 40 * gb, reserveBytes: 20 * gb)
    expect(free) == 10 * gb
  }

  func testNeverNegative() {
    let free = HeadroomPolicy.bytesToFree(
      availableBytes: 200 * gb, needing: 1 * gb, reserveBytes: 20 * gb)
    expect(free) == 0
  }
}

final class EvictionPolicyTests: XCTestCase {
  private let gb: Int64 = 1_073_741_824

  /// Build one candidate. `agoSeconds` sets how long ago it was last used, so a
  /// larger value is older and therefore evicted first within a priority tier.
  private func candidate(
    _ id: String,
    sizeGB: Int64,
    agoSeconds: TimeInterval,
    inFlight: Int = 0,
    priority: Int? = nil,
    pinned: Bool = false,
    isEmbedding: Bool = false
  ) -> EvictionCandidate {
    EvictionCandidate(
      modelID: id,
      sizeBytes: sizeGB * gb,
      lastUsed: Date().addingTimeInterval(-agoSeconds),
      inFlightRequests: inFlight,
      isEmbedding: isEmbedding,
      priority: priority,
      pinned: pinned
    )
  }

  func testNothingToFreeReturnsEmpty() {
    let plan = EvictionPolicy.planEvictionToFree(candidates: [], bytesToFree: 0)
    expect(plan.isEmpty) == true
  }

  func testEvictsOldestIdleFirst() {
    let older = candidate("A", sizeGB: 20, agoSeconds: 3_600)
    let newer = candidate("B", sizeGB: 20, agoSeconds: 600)
    // Need to free 10 GB. The oldest idle model alone (A, 20 GB) covers it.
    let plan = EvictionPolicy.planEvictionToFree(candidates: [newer, older], bytesToFree: 10 * gb)
    expect(plan.idle) == ["A"]
    expect(plan.busy.isEmpty) == true
  }

  func testIdleCoversTargetLeavesBusyAlone() {
    let busy = candidate("busy", sizeGB: 40, agoSeconds: 7_200, inFlight: 2)
    let idleSmall = candidate("idle", sizeGB: 10, agoSeconds: 60)
    // The idle model alone covers the target, so the busy one is not touched.
    let plan = EvictionPolicy.planEvictionToFree(
      candidates: [busy, idleSmall], bytesToFree: 5 * gb)
    expect(plan.idle) == ["idle"]
    expect(plan.busy.isEmpty) == true
  }

  func testDrainsBusyLowerPriorityWhenIdleInsufficient() {
    // A high-priority load (chat, 100) needs 40 GB. Only a 10 GB idle model can
    // move on its own, so the busy lower-priority embedding model is added as a
    // drain-and-preempt victim.
    let busyEmbed = candidate("embed", sizeGB: 60, agoSeconds: 0, inFlight: 1, isEmbedding: true)
    let idle = candidate("idle", sizeGB: 10, agoSeconds: 60)
    let plan = EvictionPolicy.planEvictionToFree(
      candidates: [busyEmbed, idle],
      bytesToFree: 40 * gb,
      requestorPriority: LoadPriority.high)
    expect(plan.idle) == ["idle"]
    expect(plan.busy) == ["embed"]
  }

  func testReturnsAllEligibleWhenInsufficient() {
    // No busy victim is eligible to preempt, and the single idle model cannot
    // reach the target, so it is returned anyway for the caller to re-measure.
    let idle = candidate("idle", sizeGB: 10, agoSeconds: 60)
    let plan = EvictionPolicy.planEvictionToFree(candidates: [idle], bytesToFree: 40 * gb)
    expect(plan.idle) == ["idle"]
    expect(plan.busy.isEmpty) == true
  }

  func testEvictsMultipleIfNeeded() {
    let older = candidate("A", sizeGB: 10, agoSeconds: 3_600)
    let newer = candidate("B", sizeGB: 10, agoSeconds: 1_800)
    // Need 15 GB. One model frees 10, so both are needed, oldest first.
    let plan = EvictionPolicy.planEvictionToFree(candidates: [newer, older], bytesToFree: 15 * gb)
    expect(plan.idle) == ["A", "B"]
  }

  func testEvictsEmbeddingBeforeChatWhenBothIdle() {
    // Embedding defaults to the low priority tier, so it is reclaimed before chat
    // even though it was used more recently. This inverts the prior policy, which
    // protected embeddings; protecting chat and video is the point of the change.
    let chat = candidate("chat", sizeGB: 30, agoSeconds: 7_200, isEmbedding: false)
    let embed = candidate("embed", sizeGB: 30, agoSeconds: 3_600, isEmbedding: true)
    let plan = EvictionPolicy.planEvictionToFree(candidates: [chat, embed], bytesToFree: 30 * gb)
    expect(plan.idle) == ["embed"]
  }

  func testRequestorCannotEvictHigherOrEqualPriority() {
    // An embedding load (priority 10) cannot reclaim an idle chat model (100).
    let idleChat = candidate("chat", sizeGB: 30, agoSeconds: 7_200, isEmbedding: false)
    let plan = EvictionPolicy.planEvictionToFree(
      candidates: [idleChat],
      bytesToFree: 30 * gb,
      requestorPriority: LoadPriority.low)
    expect(plan.isEmpty) == true
  }

  func testPinnedModelIsNeverChosen() {
    let pinned = candidate("pinned", sizeGB: 30, agoSeconds: 7_200, pinned: true)
    let plan = EvictionPolicy.planEvictionToFree(candidates: [pinned], bytesToFree: 30 * gb)
    expect(plan.isEmpty) == true
  }

  func testDoesNotPreemptEqualPriorityBusyPeer() {
    // A chat load cannot preempt another busy chat model at the same priority.
    let busyChat = candidate("peer", sizeGB: 30, agoSeconds: 0, inFlight: 1, isEmbedding: false)
    let plan = EvictionPolicy.planEvictionToFree(
      candidates: [busyChat],
      bytesToFree: 30 * gb,
      requestorPriority: LoadPriority.high)
    expect(plan.isEmpty) == true
  }

  func testOrdersLowestPriorityThenLeastRecentlyUsed() {
    let lowOld = candidate("low-old", sizeGB: 5, agoSeconds: 300, priority: 10)
    let lowNew = candidate("low-new", sizeGB: 5, agoSeconds: 100, priority: 10)
    let mid = candidate("mid", sizeGB: 5, agoSeconds: 9_999, priority: 50)
    // Need more than every model combined, so all are returned in reclaim order:
    // lowest priority first, and within a priority the least-recently-used first.
    let plan = EvictionPolicy.planEvictionToFree(
      candidates: [mid, lowNew, lowOld], bytesToFree: 100 * gb)
    expect(plan.idle) == ["low-old", "low-new", "mid"]
  }
}
