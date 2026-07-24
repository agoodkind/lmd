//
//  EmbeddingBackend.swift
//  SwiftLMBackend
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-04-19.
//  Copyright © 2026, all rights reserved.
//

import Foundation
import SwiftLMCore

/// One embedding forward pass: the pooled vectors and the real input token
/// count the backend tokenized for this batch. The token count is what the
/// backend actually embedded (post-truncation for backends that truncate), so
/// it matches the `lmd_embed_batch_tokens_real` metric and feeds the OpenAI
/// `usage` fields.
public struct EmbeddingForwardResult: Sendable {
  public let rows: [[Float]]
  public let realTokens: Int

  public init(rows: [[Float]], realTokens: Int) {
    self.rows = rows
    self.realTokens = realTokens
  }
}

// MARK: - EmbeddingInputTooLong

/// One embedding input tokenized to more tokens than the model can embed. A
/// tokenizer-owning backend throws this instead of silently truncating, so the
/// broker can return an OpenAI-style 400 `context_length_exceeded` error and the
/// caller learns the input was rejected rather than quietly cut.
public struct EmbeddingInputTooLong: Error, Sendable, Equatable {
  public let index: Int
  public let tokenCount: Int
  public let limit: Int

  public init(index: Int, tokenCount: Int, limit: Int) {
    self.index = index
    self.tokenCount = tokenCount
    self.limit = limit
  }
}

// MARK: - EmbeddingBackendProtocol

/// In process embedding backend. No TCP port. MLXEmbedders lives in SwiftLMEmbed.
public protocol EmbeddingBackendProtocol: AnyObject, Sendable {
  /// Same key as ``ModelDescriptor/id`` (disk path).
  var modelID: String { get }
  var sizeBytes: Int64 { get }
  func launch() async throws
  func shutdown()
  /// Run a forward pass for one batch of input strings, returning the pooled
  /// vectors (L2 normalized when the pooler does so) and the real token count
  /// the backend tokenized. The count is a byproduct of the pass, so callers get
  /// honest usage without tokenizing a second time.
  func embed(inputs: [String]) async throws -> EmbeddingForwardResult
  /// Total token estimate for a request, used only for priority-lane classification.
  func countTokens(inputs: [String]) -> Int
  /// Apply a battery throttle level. MLX backends shrink the allocator cache at
  /// `hard` and restore it otherwise. The default is a no-op so backends that do
  /// not manage a GPU cache are unaffected.
  func applyPowerThrottle(_ level: PowerThrottleLevel)
}

// MARK: - EmbeddingBackendTokenEstimator

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

// MARK: - EmbeddingBackendProtocol defaults

extension EmbeddingBackendProtocol {
  /// Total token estimate for a request, used only for priority-lane
  /// classification. The default approximates four UTF-8 bytes per token with a
  /// per-input floor of one; tokenizer-owning backends override with real counts.
  public func countTokens(inputs: [String]) -> Int {
    EmbeddingBackendTokenEstimator.countTokens(inputs: inputs)
  }

  public func applyPowerThrottle(_: PowerThrottleLevel) {}
}

// MARK: - UnsupportedEmbeddingBackendError

public protocol UnsupportedEmbeddingBackendError: Error, CustomStringConvertible, Sendable {}
