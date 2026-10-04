//
//  EmbeddingSlicePlan.swift
//  lmd-model-host
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-10-04.
//  Copyright © 2026, all rights reserved.
//

import Foundation

enum EmbeddingSlicePlan {
  /// Splits the inputs of one request into consecutive index ranges. A range
  /// closes before the input that would raise its token total above
  /// `maxTokens`. An input above `maxTokens` gets a range of its own.
  static func ranges(tokenCounts: [Int], maxTokens: Int) -> [Range<Int>] {
    var ranges: [Range<Int>] = []
    var start = 0
    var total = 0
    for (index, count) in tokenCounts.enumerated() {
      if index > start, total + count > maxTokens {
        ranges.append(start..<index)
        start = index
        total = 0
      }
      total += count
    }
    if start < tokenCounts.count {
      ranges.append(start..<tokenCounts.count)
    }
    return ranges
  }
}
