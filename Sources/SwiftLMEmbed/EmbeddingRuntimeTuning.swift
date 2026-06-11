//
//  EmbeddingRuntimeTuning.swift
//  SwiftLMEmbed
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-06-10.
//  Copyright © 2026, all rights reserved.
//

import Foundation

/// The per-host tuning values the broker resolves and passes via argv; fallback
/// applies when a host is launched without flags.
public struct EmbeddingRuntimeTuning: Equatable, Sendable {
  /// Fallback padded-slot budget per forward when no flag arrives.
  public static let fallbackSlotBudget = 8_192
  /// Fallback row cap per sub-batch when no flag arrives.
  public static let fallbackMaxRows = 256
  /// Fallback priority-lane input-count threshold when no flag arrives.
  public static let fallbackPriorityMaxInputs = 2
  /// Fallback priority-lane real-token threshold when no flag arrives.
  public static let fallbackPriorityMaxTokens = 2_048
  /// Fallback forward concurrency when no flag arrives.
  public static let fallbackMaxConcurrentForwards = 1

  public let slotBudget: Int
  public let maxRows: Int
  public let priorityMaxInputs: Int
  public let priorityMaxTokens: Int
  public let priorityLaneEnabled: Bool
  public let maxConcurrentForwards: Int

  public static let fallback = EmbeddingRuntimeTuning(
    slotBudget: fallbackSlotBudget,
    maxRows: fallbackMaxRows,
    priorityMaxInputs: fallbackPriorityMaxInputs,
    priorityMaxTokens: fallbackPriorityMaxTokens,
    priorityLaneEnabled: true,
    maxConcurrentForwards: fallbackMaxConcurrentForwards
  )

  public init(
    slotBudget: Int,
    maxRows: Int,
    priorityMaxInputs: Int,
    priorityMaxTokens: Int,
    priorityLaneEnabled: Bool,
    maxConcurrentForwards: Int
  ) {
    self.slotBudget = slotBudget
    self.maxRows = maxRows
    self.priorityMaxInputs = priorityMaxInputs
    self.priorityMaxTokens = priorityMaxTokens
    self.priorityLaneEnabled = priorityLaneEnabled
    self.maxConcurrentForwards = maxConcurrentForwards
  }
}
