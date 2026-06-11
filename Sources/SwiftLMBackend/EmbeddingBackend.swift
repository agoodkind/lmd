//
//  EmbeddingBackend.swift
//  SwiftLMBackend
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-04-19.
//  Copyright © 2026, all rights reserved.
//

import Foundation
import SwiftLMCore

/// In process embedding backend. No TCP port. MLXEmbedders lives in SwiftLMEmbed.
public protocol EmbeddingBackendProtocol: AnyObject, Sendable {
  /// Same key as ``ModelDescriptor/id`` (disk path).
  var modelID: String { get }
  var sizeBytes: Int64 { get }
  func launch() async throws
  func shutdown()
  /// Run a forward pass for one batch of input strings. Vectors are L2 normalized when the pooler does so.
  func embed(inputs: [String]) async throws -> [[Float]]
  /// Total token estimate for a request, used only for priority-lane classification.
  func countTokens(inputs: [String]) -> Int
  /// Apply a battery throttle level. MLX backends shrink the allocator cache at
  /// `hard` and restore it otherwise. The default is a no-op so backends that do
  /// not manage a GPU cache are unaffected.
  func applyPowerThrottle(_ level: PowerThrottleLevel)
}

public enum EmbeddingBackendTokenEstimator {
  private static let estimatedBytesPerToken = 4
  private static let ceilingRoundingOffset = estimatedBytesPerToken - 1
  private static let minimumTokensPerInput = 1

  public static func countTokens(inputs: [String]) -> Int {
    inputs.reduce(0) { total, input in
      let estimatedTokenCount =
        (input.utf8.count + Self.ceilingRoundingOffset) / Self.estimatedBytesPerToken
      return total + Self.flooredTokenCount(estimatedTokenCount)
    }
  }

  public static func countTokens(encodedInputs: [[Int]]) -> Int {
    encodedInputs.reduce(0) { total, input in
      total + Self.flooredTokenCount(input.count)
    }
  }

  private static func flooredTokenCount(_ tokenCount: Int) -> Int {
    max(tokenCount, Self.minimumTokensPerInput)
  }
}

extension EmbeddingBackendProtocol {
  /// Total token estimate for a request, used only for priority-lane
  /// classification. The default approximates four UTF-8 bytes per token with a
  /// per-input floor of one; tokenizer-owning backends override with real counts.
  public func countTokens(inputs: [String]) -> Int {
    EmbeddingBackendTokenEstimator.countTokens(inputs: inputs)
  }

  public func applyPowerThrottle(_: PowerThrottleLevel) {}
}

public protocol UnsupportedEmbeddingBackendError: Error, CustomStringConvertible, Sendable {}
