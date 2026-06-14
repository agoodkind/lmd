//
//  ModelLoadConfig.swift
//  SwiftLMRuntime
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-05-23.
//  Copyright © 2026, all rights reserved.
//

import Foundation
import SwiftLMCore

// MARK: - LoadPriority

/// Eviction priority tiers. A load can only preempt a busy model whose priority
/// is strictly lower, and idle eviction prefers the lowest priority first, so
/// chat and video models keep their memory while embedding models yield it.
public enum LoadPriority {
  /// Default for chat and video models: kept resident under contention.
  public static let high = 100
  /// Default for embedding models: the first to be evicted or preempted.
  public static let low = 10

  /// The default priority for a model of `kind` when none is set explicitly.
  public static func kindDefault(for kind: ModelKind) -> Int {
    kind == .embedding ? low : high
  }
}

// MARK: - ModelLoadConfig

public struct ModelLoadConfig: Codable, Sendable, Equatable {
  public let identifier: String?
  public let contextLength: Int?
  public let evalBatchSize: Int?
  public let flashAttention: Bool?
  public let offloadKVCacheToGPU: Bool?
  public let gpu: String?
  public let ttlSeconds: Int?
  /// Explicit eviction priority override. When nil, the kind default applies.
  public let priority: Int?
  /// When true, the model is never auto-unloaded, evicted, or preempted.
  public let pinned: Bool
  public let ignoredFields: [String]

  public init(
    identifier: String? = nil,
    contextLength: Int? = nil,
    evalBatchSize: Int? = nil,
    flashAttention: Bool? = nil,
    offloadKVCacheToGPU: Bool? = nil,
    gpu: String? = nil,
    ttlSeconds: Int? = nil,
    priority: Int? = nil,
    pinned: Bool = false,
    ignoredFields: [String] = []
  ) {
    self.identifier = Self.normalizedString(identifier)
    self.contextLength = Self.positiveInt(contextLength)
    self.evalBatchSize = Self.positiveInt(evalBatchSize)
    self.flashAttention = flashAttention
    self.offloadKVCacheToGPU = offloadKVCacheToGPU
    self.gpu = Self.normalizedString(gpu)
    self.ttlSeconds = Self.positiveInt(ttlSeconds)
    self.priority = priority
    self.pinned = pinned
    self.ignoredFields = ignoredFields.sorted()
  }

  public static let `default` = ModelLoadConfig()

  /// Resolved eviction priority for a model of `kind`, applying the explicit
  /// override when present and the kind default otherwise.
  public func effectivePriority(for kind: ModelKind) -> Int {
    priority ?? LoadPriority.kindDefault(for: kind)
  }

  /// Whether the model is pinned and therefore exempt from every eviction path.
  public var isPinned: Bool {
    pinned
  }

  public func normalized(for kind: ModelKind) -> ModelLoadConfig {
    var ignored = ignoredFields
    if evalBatchSize != nil {
      ignored.append("eval_batch_size")
    }
    if flashAttention != nil {
      ignored.append("flash_attention")
    }
    if offloadKVCacheToGPU != nil {
      ignored.append("offload_kv_cache_to_gpu")
    }
    if gpu != nil {
      ignored.append("gpu")
    }

    return ModelLoadConfig(
      identifier: identifier,
      contextLength: contextLength,
      evalBatchSize: kind == .chat ? evalBatchSize : nil,
      flashAttention: kind == .chat ? flashAttention : nil,
      offloadKVCacheToGPU: kind == .chat ? offloadKVCacheToGPU : nil,
      gpu: kind == .chat ? gpu : nil,
      ttlSeconds: ttlSeconds,
      priority: priority,
      pinned: pinned,
      ignoredFields: Array(Set(ignored))
    )
  }

  public func merged(with override: ModelLoadConfig?) -> ModelLoadConfig {
    guard let override else {
      return self
    }
    return ModelLoadConfig(
      identifier: override.identifier ?? identifier,
      contextLength: override.contextLength ?? contextLength,
      evalBatchSize: override.evalBatchSize ?? evalBatchSize,
      flashAttention: override.flashAttention ?? flashAttention,
      offloadKVCacheToGPU: override.offloadKVCacheToGPU ?? offloadKVCacheToGPU,
      gpu: override.gpu ?? gpu,
      ttlSeconds: override.ttlSeconds ?? ttlSeconds,
      priority: override.priority ?? priority,
      pinned: pinned || override.pinned,
      ignoredFields: Array(Set(ignoredFields).union(override.ignoredFields))
    )
  }

  private static func normalizedString(_ value: String?) -> String? {
    guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty
    else {
      return nil
    }
    return trimmed
  }

  private static func positiveInt(_ value: Int?) -> Int? {
    guard let value, value > 0 else {
      return nil
    }
    return value
  }

  enum CodingKeys: String, CodingKey {
    case identifier
    case contextLength = "context_length"
    case evalBatchSize = "eval_batch_size"
    case flashAttention = "flash_attention"
    case offloadKVCacheToGPU = "offload_kv_cache_to_gpu"
    case gpu
    case ttlSeconds = "ttl"
    case priority
    case pinned
    case ignoredFields = "ignored_fields"
  }
}
