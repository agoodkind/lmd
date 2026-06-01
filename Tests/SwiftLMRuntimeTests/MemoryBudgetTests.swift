//
//  MemoryBudgetTests.swift
//  SwiftLMRuntimeTests
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-04-18.
//  Copyright © 2026, all rights reserved.
//

import XCTest

@testable import SwiftLMRuntime

final class HeadroomPolicyTests: XCTestCase {
  private let gb: Int64 = 1_073_741_824

  func testNoFreeNeededWhenReserveHolds() {
    // 100 available, load needs 40, keep 20 free -> 60 remains, nothing to free.
    let free = HeadroomPolicy.bytesToFree(
      availableBytes: 100 * gb, needing: 40 * gb, reserveBytes: 20 * gb)
    XCTAssertEqual(free, 0)
  }

  func testFreeNeededWhenLoadWouldBreachReserve() {
    // 50 available, load needs 40, keep 20 free -> short by 10.
    let free = HeadroomPolicy.bytesToFree(
      availableBytes: 50 * gb, needing: 40 * gb, reserveBytes: 20 * gb)
    XCTAssertEqual(free, 10 * gb)
  }

  func testNeverNegative() {
    let free = HeadroomPolicy.bytesToFree(
      availableBytes: 200 * gb, needing: 1 * gb, reserveBytes: 20 * gb)
    XCTAssertEqual(free, 0)
  }
}

final class EvictionPolicyTests: XCTestCase {
  private let gb: Int64 = 1_073_741_824

  func testNothingToFreeReturnsEmpty() {
    let plan = EvictionPolicy.planEvictionToFree(candidates: [], bytesToFree: 0)
    XCTAssertTrue(plan.isEmpty)
  }

  func testEvictsOldestIdleFirst() {
    let now = Date()
    let a = EvictionCandidate(
      modelID: "A", sizeBytes: 20 * gb,
      lastUsed: now.addingTimeInterval(-3600), inFlightRequests: 0)
    let b = EvictionCandidate(
      modelID: "B", sizeBytes: 20 * gb,
      lastUsed: now.addingTimeInterval(-600), inFlightRequests: 0)
    // Need to free 10 GB. The oldest idle model alone (A, 20 GB) covers it.
    let plan = EvictionPolicy.planEvictionToFree(candidates: [b, a], bytesToFree: 10 * gb)
    XCTAssertEqual(plan, ["A"])
  }

  func testNeverEvictsBusyModels() {
    let now = Date()
    let busy = EvictionCandidate(
      modelID: "busy", sizeBytes: 40 * gb,
      lastUsed: now.addingTimeInterval(-7200), inFlightRequests: 2)
    let idleSmall = EvictionCandidate(
      modelID: "idle", sizeBytes: 10 * gb,
      lastUsed: now.addingTimeInterval(-60), inFlightRequests: 0)
    let plan = EvictionPolicy.planEvictionToFree(
      candidates: [busy, idleSmall], bytesToFree: 5 * gb)
    XCTAssertEqual(plan, ["idle"])
  }

  func testReturnsAllIdleWhenInsufficient() {
    let now = Date()
    let busy = EvictionCandidate(
      modelID: "busy", sizeBytes: 60 * gb, lastUsed: now, inFlightRequests: 1)
    let idle = EvictionCandidate(
      modelID: "idle", sizeBytes: 10 * gb,
      lastUsed: now.addingTimeInterval(-60), inFlightRequests: 0)
    // Need 40 GB but only the 10 GB idle model can move. Return it anyway so the
    // caller unloads it and re-measures.
    let plan = EvictionPolicy.planEvictionToFree(candidates: [busy, idle], bytesToFree: 40 * gb)
    XCTAssertEqual(plan, ["idle"])
  }

  func testEvictsMultipleIfNeeded() {
    let now = Date()
    let a = EvictionCandidate(
      modelID: "A", sizeBytes: 10 * gb,
      lastUsed: now.addingTimeInterval(-3600), inFlightRequests: 0)
    let b = EvictionCandidate(
      modelID: "B", sizeBytes: 10 * gb,
      lastUsed: now.addingTimeInterval(-1800), inFlightRequests: 0)
    // Need 15 GB. One model frees 10, so both are needed, oldest first.
    let plan = EvictionPolicy.planEvictionToFree(candidates: [b, a], bytesToFree: 15 * gb)
    XCTAssertEqual(plan, ["A", "B"])
  }

  func testEvictsChatBeforeEmbeddingWhenBothIdle() {
    let now = Date()
    let chat = EvictionCandidate(
      modelID: "chat", sizeBytes: 30 * gb,
      lastUsed: now.addingTimeInterval(-7200), inFlightRequests: 0, isEmbedding: false)
    let embed = EvictionCandidate(
      modelID: "embed", sizeBytes: 30 * gb,
      lastUsed: now.addingTimeInterval(-3600), inFlightRequests: 0, isEmbedding: true)
    // Need 30 GB. Chat goes first even though it is older than the embedding cutoff.
    let plan = EvictionPolicy.planEvictionToFree(candidates: [embed, chat], bytesToFree: 30 * gb)
    XCTAssertEqual(plan, ["chat"])
  }
}
