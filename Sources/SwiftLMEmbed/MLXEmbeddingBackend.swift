//
//  MLXEmbeddingBackend.swift
//  SwiftLMEmbed
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-04-19.
//  Copyright © 2026, all rights reserved.
//

import Foundation
import MLX
import MLXEmbedders
import MLXHuggingFace
import MLXLMCommon
import SwiftLMBackend
import SwiftLMCore
import SwiftLMTrace
import Tokenizers

public enum MLXEmbeddingRuntimeError: Error {
  case modelNotLoaded
}

/// Loads weights from ``ModelDescriptor/path`` via MLXEmbedders and runs batched pooling.
public final class MLXEmbeddingBackend: EmbeddingBackendProtocol, @unchecked Sendable {
  private let descriptor: ModelDescriptor
  private var container: MLXEmbedders.EmbedderModelContainer?

  public var modelID: String { descriptor.id }
  public var sizeBytes: Int64 { descriptor.sizeBytes }

  public init(descriptor: ModelDescriptor) {
    self.descriptor = descriptor
  }

  private var traceBackendObjectID: String {
    TraceContext.backendObjectID(of: self)
  }

  private func lifecycleContext() -> TraceContext {
    TraceContext(
      modelID: descriptor.id,
      modelKind: .embedding,
      loadID: TraceTaskLocal.loadID,
      backendObjectID: traceBackendObjectID
    )
  }

  private func requestContext() -> TraceContext {
    TraceContext(
      modelID: descriptor.id,
      modelKind: .embedding,
      loadID: TraceTaskLocal.loadID,
      backendObjectID: traceBackendObjectID,
      requestID: TraceTaskLocal.requestID
    )
  }

  public func launch() async throws {
    BackendTrace.notice(
      phase: TracePhase.Embedding.spawnBegin.rawValue,
      context: lifecycleContext(),
      snapshot: .current()
    )
    let resolved = ResolvedModelConfiguration(
      directory: URL(fileURLWithPath: descriptor.path))
    let context = try await EmbedderModelFactory.shared._load(
      configuration: resolved,
      tokenizerLoader: #huggingFaceTokenizerLoader()
    )
    container = EmbedderModelFactory.shared._wrap(context)
    // Bound MLX's allocator cache; see NVEmbeddingBackend for the
    // rationale and the trace data this is calibrated against.
    Memory.cacheLimit = MLXEmbeddingBackend.cacheLimitBytes
    BackendTrace.notice(
      phase: TracePhase.Embedding.spawnRuntimeReady.rawValue,
      context: lifecycleContext(),
      snapshot: .current()
    )
  }

  /// Mirrors `NVEmbeddingBackend.cacheLimitBytes`. See the rationale on
  /// that constant for why this value is the contract.
  static var cacheLimitBytes: Int { configuredEmbeddingCacheLimitBytes() }

  /// Shrink the MLX allocator cache under a `hard` battery throttle, restoring
  /// the configured cap for `none`/`mild`. Applied between requests by the
  /// router; with concurrency throttled there is a clean moment to change it.
  public func applyPowerThrottle(_ level: PowerThrottleLevel) {
    switch level {
    case .none, .mild:
      Memory.cacheLimit = MLXEmbeddingBackend.cacheLimitBytes
    case .hard:
      Memory.cacheLimit = throttledEmbeddingCacheLimitBytes
    }
  }

  public func shutdown() {
    guard container != nil else {
      return
    }
    BackendTrace.notice(
      phase: TracePhase.Embedding.shutdownPre.rawValue,
      context: lifecycleContext(),
      snapshot: .current()
    )
    container = nil
    BackendTrace.notice(
      phase: TracePhase.Embedding.shutdownRuntimeNil.rawValue,
      context: lifecycleContext(),
      snapshot: .current()
    )
    Memory.clearCache()
    BackendTrace.notice(
      phase: TracePhase.Embedding.shutdownPostClearCache.rawValue,
      context: lifecycleContext(),
      snapshot: .current()
    )
  }

  public func embed(inputs: [String]) async throws -> [[Float]] {
    guard let container else {
      throw MLXEmbeddingRuntimeError.modelNotLoaded
    }
    BackendTrace.debug(
      phase: TracePhase.Embedding.requestPreTokenize.rawValue,
      context: requestContext(),
      snapshot: .current(),
      extras: ["input_count": "\(inputs.count)"]
    )
    let traceCtx = requestContext()
    return await container.perform { context in
      let encoded = inputs.map { context.tokenizer.encode(text: $0, addSpecialTokens: true) }
      let maxLength = encoded.reduce(into: 1) { acc, elem in
        acc = max(acc, elem.count)
      }
      let padId = context.tokenizer.eosTokenId ?? 0
      let padded = stacked(
        encoded.map { elem in
          MLXArray(
            elem + Array(repeating: padId, count: maxLength - elem.count))
        })
      let batchSize = encoded.count
      let totalTokens = encoded.reduce(0) { $0 + $1.count }
      let totalSlots = batchSize * maxLength
      let paddingRatio =
        totalSlots > 0 ? Double(totalSlots - totalTokens) / Double(totalSlots) : 0.0
      BackendTrace.debug(
        phase: TracePhase.Embedding.requestPostTokenize.rawValue,
        context: traceCtx,
        snapshot: .current(),
        extras: [
          "batch_size": "\(batchSize)",
          "max_seq_len": "\(maxLength)",
          "total_tokens": "\(totalTokens)",
          "padding_ratio": String(format: "%.4f", paddingRatio),
        ]
      )
      let mask = (padded .!= padId)
      let tokenTypes = MLXArray.zeros(like: padded)
      BackendTrace.debug(
        phase: TracePhase.Embedding.requestPreForward.rawValue,
        context: traceCtx,
        snapshot: .current()
      )
      let modelOutput = context.model(
        padded, positionIds: nil, tokenTypeIds: tokenTypes, attentionMask: mask)
      BackendTrace.debug(
        phase: TracePhase.Embedding.requestPostForward.rawValue,
        context: traceCtx,
        snapshot: .current()
      )
      let result = context.pooling(modelOutput, normalize: true, applyLayerNorm: true)
      BackendTrace.debug(
        phase: TracePhase.Embedding.requestPostPool.rawValue,
        context: traceCtx,
        snapshot: .current()
      )
      result.eval()
      BackendTrace.debug(
        phase: TracePhase.Embedding.requestPostEval.rawValue,
        context: traceCtx,
        snapshot: .current()
      )
      let batchCount = result.shape[0]
      var rows: [[Float]] = []
      rows.reserveCapacity(batchCount)
      for i in 0..<batchCount {
        rows.append(result[i].asArray(Float.self))
      }
      BackendTrace.debug(
        phase: TracePhase.Embedding.requestPreReturn.rawValue,
        context: traceCtx,
        snapshot: .current(),
        extras: ["row_count": "\(rows.count)"]
      )
      return rows
    }
  }
}
