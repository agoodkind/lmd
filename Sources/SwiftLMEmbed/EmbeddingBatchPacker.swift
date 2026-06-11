//
//  EmbeddingBatchPacker.swift
//  SwiftLMEmbed
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-06-11.
//  Copyright © 2026, all rights reserved.
//
//  Packs tokenized inputs into sub-batches under a padded-slot budget.
//  Padded slots for a group are rows x the group's longest input, which is
//  exactly the work the forward pass performs, so the budget bounds wasted
//  padding compute directly. A length-spread cap additionally bounds the
//  padding RATIO inside a group: under a large slot budget, pure greedy
//  packing would lump very short inputs with much longer ones and pay most
//  of the budget as padding (observed 60 percent on a mixed bench corpus).
//

private let emptyGroupMaxLength = 0
private let minimumInputLength = 1
/// A group never spans more than this factor between its shortest and
/// longest input, which bounds per-group padding at 1 - 1/factor (50
/// percent worst case, far less in practice since lengths arrive sorted).
private let maxGroupLengthSpreadFactor = 2

enum EmbeddingBatchPacker {
  /// Returns groups of indexes into `lengths`. Inputs are visited in
  /// ascending length order so short inputs never pad to a long input's
  /// length. A group closes when adding the next input would push
  /// rows x groupMaxLength past `slotBudget`, rows past `maxRows`, or the
  /// group's length spread past `maxGroupLengthSpreadFactor`. An input
  /// longer than the whole budget forms a group of one. Every index lands in
  /// exactly one group.
  static func pack(lengths: [Int], slotBudget: Int, maxRows: Int) -> [[Int]] {
    precondition(slotBudget > emptyGroupMaxLength, "slotBudget must be positive")
    precondition(maxRows > emptyGroupMaxLength, "maxRows must be positive")

    let ascending = lengths.indices.sorted { lengths[$0] < lengths[$1] }
    var groups: [[Int]] = []
    var current: [Int] = []
    var currentMaxLength = emptyGroupMaxLength
    var currentMinLength = emptyGroupMaxLength

    for index in ascending {
      let length = max(lengths[index], minimumInputLength)
      let prospectiveMax = max(currentMaxLength, length)
      let prospectiveSlots = (current.count + minimumInputLength) * prospectiveMax
      let wouldExceedBudget = prospectiveSlots > slotBudget
      let wouldExceedRows = current.count + minimumInputLength > maxRows
      let wouldExceedSpread =
        currentMinLength > emptyGroupMaxLength
        && length > currentMinLength * maxGroupLengthSpreadFactor
      let wouldOverflow = wouldExceedBudget || wouldExceedRows || wouldExceedSpread

      if !current.isEmpty && wouldOverflow {
        groups.append(current)
        current = []
        currentMaxLength = emptyGroupMaxLength
        currentMinLength = emptyGroupMaxLength
      }

      current.append(index)
      currentMaxLength = max(currentMaxLength, length)
      if currentMinLength == emptyGroupMaxLength {
        currentMinLength = length
      }
    }

    if !current.isEmpty {
      groups.append(current)
    }

    return groups
  }
}
