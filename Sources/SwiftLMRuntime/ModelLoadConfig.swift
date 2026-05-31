//
//  ModelLoadConfig.swift
//  SwiftLMRuntime
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-05-23.
//  Copyright © 2026, all rights reserved.
//

import Foundation
import SwiftLMCore

public struct ModelLoadConfig: Codable, Sendable, Equatable {
  public let identifier: String?
  public let contextLength: Int?
  public let evalBatchSize: Int?
  public let flashAttention: Bool?
  public let offloadKVCacheToGPU: Bool?
  public let gpu: String?
  public let ttlSeconds: Int?
  public let ignoredFields: [String]

  public init(
    identifier: String? = nil,
    contextLength: Int? = nil,
    evalBatchSize: Int? = nil,
    flashAttention: Bool? = nil,
    offloadKVCacheToGPU: Bool? = nil,
    gpu: String? = nil,
    ttlSeconds: Int? = nil,
    ignoredFields: [String] = []
  ) {
    self.identifier = Self.normalizedString(identifier)
    self.contextLength = Self.positiveInt(contextLength)
    self.evalBatchSize = Self.positiveInt(evalBatchSize)
    self.flashAttention = flashAttention
    self.offloadKVCacheToGPU = offloadKVCacheToGPU
    self.gpu = Self.normalizedString(gpu)
    self.ttlSeconds = Self.positiveInt(ttlSeconds)
    self.ignoredFields = ignoredFields.sorted()
  }

  public static let `default` = ModelLoadConfig()

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
    case ignoredFields = "ignored_fields"
  }
}
