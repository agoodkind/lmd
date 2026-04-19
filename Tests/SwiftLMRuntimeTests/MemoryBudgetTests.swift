//
//  MemoryBudgetTests.swift
//  SwiftLMRuntimeTests
//
//  Created by Alex Goodkind <alex@goodkind.io> on 2026-04-18.
//  Copyright © 2026
//

import XCTest
@testable import SwiftLMRuntime

final class MemoryBudgetTests: XCTestCase {
  // 128 GB ceiling, 48 GB reserve -> 80 GB usable.
  private let budget = MemoryBudget(
    ceilingBytes: 128 * 1_073_741_824,
    reservedBytes: 48 * 1_073_741_824
  )

  func testUsableSubtractsReserve() {
    XCTAssertEqual(budget.usable, 80 * 1_073_741_824)
  }

  func testCanAccommodateUnderCeiling() {
    XCTAssertTrue(budget.canAccommodate(
      currentlyAllocated: 30 * 1_073_741_824,
      needing: 40 * 1_073_741_824
    ))
  }

  func testCannotAccommodateOverCeiling() {
    XCTAssertFalse(budget.canAccommodate(
      currentlyAllocated: 60 * 1_073_741_824,
      needing: 40 * 1_073_741_824
    ))
  }

  func testOverCommitment() {
    let over = budget.overCommitmentIfAdding(
      currentlyAllocated: 70 * 1_073_741_824,
      needing: 30 * 1_073_741_824
    )
    // 70 + 30 = 100, usable = 80. 20 GB over.
    XCTAssertEqual(over, 20 * 1_073_741_824)
  }
}

final class EvictionPolicyTests: XCTestCase {
  private let gb: Int64 = 1_073_741_824
  private let budget = MemoryBudget(ceilingBytes: 128 * 1_073_741_824, reservedBytes: 48 * 1_073_741_824)

  func testNoEvictionWhenFitsAlready() {
    let plan = EvictionPolicy.planEviction(
      candidates: [],
      needing: 10 * gb,
      budget: budget,
      currentlyAllocated: 20 * gb
    )
    XCTAssertTrue(plan.isEmpty)
  }

  func testEvictsOldestIdleFirst() {
    let now = Date()
    let a = EvictionCandidate(modelID: "A", sizeBytes: 20 * gb,
                               lastUsed: now.addingTimeInterval(-3600), inFlightRequests: 0)
    let b = EvictionCandidate(modelID: "B", sizeBytes: 20 * gb,
                               lastUsed: now.addingTimeInterval(-600), inFlightRequests: 0)
    // allocated = 40, usable = 80, needing = 50 -> over by 10, must evict oldest (A)
    let plan = EvictionPolicy.planEviction(
      candidates: [b, a],
      needing: 50 * gb,
      budget: budget,
      currentlyAllocated: 40 * gb
    )
    XCTAssertEqual(plan, ["A"])
  }

  func testNeverEvictsBusyModels() {
    let now = Date()
    let busy = EvictionCandidate(modelID: "busy", sizeBytes: 40 * gb,
                                  lastUsed: now.addingTimeInterval(-7200), inFlightRequests: 2)
    let idleSmall = EvictionCandidate(modelID: "idle", sizeBytes: 10 * gb,
                                       lastUsed: now.addingTimeInterval(-60), inFlightRequests: 0)
    // allocated = 50, need 35 -> 5 over. Only idle can go, which would free 10.
    let plan = EvictionPolicy.planEviction(
      candidates: [busy, idleSmall],
      needing: 35 * gb,
      budget: budget,
      currentlyAllocated: 50 * gb
    )
    XCTAssertEqual(plan, ["idle"])
  }

  func testReturnsEmptyWhenNoPlanFits() {
    let now = Date()
    let busy = EvictionCandidate(modelID: "busy", sizeBytes: 60 * gb,
                                  lastUsed: now, inFlightRequests: 1)
    // No idle models. Needing 40 GB when 60 allocated = 100, usable 80 -> 20 over.
    let plan = EvictionPolicy.planEviction(
      candidates: [busy],
      needing: 40 * gb,
      budget: budget,
      currentlyAllocated: 60 * gb
    )
    XCTAssertTrue(plan.isEmpty)
  }

  func testEvictsMultipleIfNeeded() {
    let now = Date()
    let a = EvictionCandidate(modelID: "A", sizeBytes: 10 * gb,
                               lastUsed: now.addingTimeInterval(-3600), inFlightRequests: 0)
    let b = EvictionCandidate(modelID: "B", sizeBytes: 10 * gb,
                               lastUsed: now.addingTimeInterval(-1800), inFlightRequests: 0)
    // allocated 20, need 70 -> over by 10. One eviction frees 10. Good.
    let plan = EvictionPolicy.planEviction(
      candidates: [a, b],
      needing: 70 * gb,
      budget: budget,
      currentlyAllocated: 20 * gb
    )
    XCTAssertEqual(plan, ["A"])
  }

  func testEvictsChatBeforeEmbeddingWhenBothIdle() {
    let now = Date()
    let chat = EvictionCandidate(
      modelID: "chat", sizeBytes: 30 * gb,
      lastUsed: now.addingTimeInterval(-7200), inFlightRequests: 0, isEmbedding: false)
    let embed = EvictionCandidate(
      modelID: "embed", sizeBytes: 30 * gb,
      lastUsed: now.addingTimeInterval(-3600), inFlightRequests: 0, isEmbedding: true)
    // 60 allocated, need 30 more -> 90 > 80. Evict one 30 GB model; chat is older but must go first.
    let plan = EvictionPolicy.planEviction(
      candidates: [embed, chat],
      needing: 30 * gb,
      budget: budget,
      currentlyAllocated: 60 * gb
    )
    XCTAssertEqual(plan, ["chat"])
  }
}
