//
//  EmbeddingBatchPackerTests.swift
//  SwiftLMEmbedTests
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-06-11.
//  Copyright © 2026, all rights reserved.
//

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
