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
//  padding compute directly.
//

private let emptyGroupMaxLength = 0
private let minimumInputLength = 1

enum EmbeddingBatchPacker {
  /// Returns groups of indexes into `lengths`. Inputs are visited in
  /// ascending length order so short inputs never pad to a long input's
  /// length. A group closes when adding the next input would push
  /// rows x groupMaxLength past `slotBudget` or rows past `maxRows`. An input
  /// longer than the whole budget forms a group of one. Every index lands in
  /// exactly one group.
  static func pack(lengths: [Int], slotBudget: Int, maxRows: Int) -> [[Int]] {
    precondition(slotBudget > emptyGroupMaxLength, "slotBudget must be positive")
    precondition(maxRows > emptyGroupMaxLength, "maxRows must be positive")

    let ascending = lengths.indices.sorted { lengths[$0] < lengths[$1] }
    var groups: [[Int]] = []
    var current: [Int] = []
    var currentMaxLength = emptyGroupMaxLength

    for index in ascending {
      let length = max(lengths[index], minimumInputLength)
      let prospectiveMax = max(currentMaxLength, length)
      let prospectiveSlots = (current.count + minimumInputLength) * prospectiveMax
      let wouldExceedBudget = prospectiveSlots > slotBudget
      let wouldExceedRows = current.count + minimumInputLength > maxRows
      let wouldOverflow = wouldExceedBudget || wouldExceedRows

      if !current.isEmpty && wouldOverflow {
        groups.append(current)
        current = []
        currentMaxLength = emptyGroupMaxLength
      }

      current.append(index)
      currentMaxLength = max(currentMaxLength, length)
    }

    if !current.isEmpty {
      groups.append(current)
    }

    return groups
  }
}
