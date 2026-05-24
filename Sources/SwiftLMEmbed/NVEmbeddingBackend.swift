//
//  NVEmbeddingBackend.swift
//  SwiftLMEmbed
//
//  Created by Alex Goodkind <alex@goodkind.io> on 2026-05-17.
//  Copyright © 2026
//

import AppLogger
import Foundation
import MLX
import MLXHuggingFace
import MLXLMCommon
import MLXNN
import SwiftLMBackend
import SwiftLMCore
import SwiftLMTrace
import Tokenizers

private let log = AppLogger.logger(category: "NVEmbeddingBackend")

public enum NVEmbeddingRuntimeError: Error, Sendable, CustomStringConvertible {
  case modelNotLoaded
  case missingHiddenStates

  public var description: String {
    switch self {
    case .modelNotLoaded:
      return "NVIDIA embedding model is not loaded"
    case .missingHiddenStates:
      return "NVIDIA embedding model did not produce hidden states"
    }
  }
}

public enum NVEmbeddingPoolingMode: String, Equatable, Sendable {
  case meanTokens = "mean_tokens"
  case clsToken = "cls_token"
  case maxTokens = "max_tokens"
  case lastToken = "last_token"
}

public struct NVEmbeddingMetadata: Equatable, Sendable {
  public let modelType: String
  public let architecture: String
  public let embeddingDimension: Int
  public let maxSequenceLength: Int
  public let poolingMode: NVEmbeddingPoolingMode
  public let includePrompt: Bool
  public let padTokenID: Int
  public let paddingSide: NVEmbeddingPaddingSide

  static func load(
    modelID: String,
    modelDir: String,
    config: EmbeddingConfigFile? = nil
  ) throws -> NVEmbeddingMetadata {
    let configFile = try config ?? EmbeddingConfigFile.load(modelID: modelID, modelDir: modelDir)
    let pooling = try NVEmbeddingPoolingConfig.load(modelID: modelID, modelDir: modelDir)
    let sentenceConfig = try NVSentenceBertConfig.load(modelID: modelID, modelDir: modelDir)
    let tokenizerConfig = NVTokenizerConfig.load(modelDir: modelDir)
    return NVEmbeddingMetadata(
      modelType: configFile.modelType ?? "mistralbidirectional",
      architecture: configFile.architectures.first ?? "MistralBiDirectionalModel",
      embeddingDimension: pooling.wordEmbeddingDimension,
      maxSequenceLength: sentenceConfig.maxSequenceLength,
      poolingMode: pooling.mode,
      includePrompt: pooling.includePrompt,
      padTokenID: tokenizerConfig.padTokenID,
      paddingSide: tokenizerConfig.paddingSide
    )
  }
}

public enum NVEmbeddingPaddingSide: String, Codable, Equatable, Sendable {
  case left
  case right
}

public final class NVEmbeddingBackend: EmbeddingBackendProtocol, @unchecked Sendable {
  private let descriptor: ModelDescriptor
  private let metadata: NVEmbeddingMetadata
  private var runtime: NVEmbeddingRuntime?

  public var modelID: String { descriptor.id }
  public var sizeBytes: Int64 { descriptor.sizeBytes }

  public init(descriptor: ModelDescriptor, metadata: NVEmbeddingMetadata) {
    self.descriptor = descriptor
    self.metadata = metadata
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
    let modelDirectory = URL(fileURLWithPath: descriptor.path)
    let data = try Data(contentsOf: modelDirectory.appendingPathComponent("config.json"))
    let configuration = try JSONDecoder().decode(
      NVMistralBiDirectionalConfiguration.self,
      from: data
    )
    BackendTrace.notice(
      phase: TracePhase.Embedding.spawnConfigParsed.rawValue,
      context: lifecycleContext(),
      snapshot: .current()
    )
    let model = NVMistralBiDirectionalModel(configuration)
    BackendTrace.notice(
      phase: TracePhase.Embedding.spawnModelConstructed.rawValue,
      context: lifecycleContext(),
      snapshot: .current()
    )
    try loadWeights(modelDirectory: modelDirectory, model: model)
    BackendTrace.notice(
      phase: TracePhase.Embedding.spawnWeightsLoaded.rawValue,
      context: lifecycleContext(),
      snapshot: .current()
    )
    let tokenizer = try await #huggingFaceTokenizerLoader().load(from: modelDirectory)
    BackendTrace.notice(
      phase: TracePhase.Embedding.spawnTokenizerLoaded.rawValue,
      context: lifecycleContext(),
      snapshot: .current()
    )
    runtime = NVEmbeddingRuntime(model: model, tokenizer: tokenizer)
    // Bound MLX's allocator cache so per-request intermediates do not
    // accumulate without limit. Data from BackendTrace `phase=tick`
    // showed `mlx_cache` growing from 4 KB to 40 GB in 80 s of indexing
    // traffic with `mlx_active` flat at the model weight; this cap holds
    // the cache near the steady-state working set instead.
    Memory.cacheLimit = NVEmbeddingBackend.cacheLimitBytes
    log.notice("nv_embedding.loaded model=\(self.descriptor.id, privacy: .public)")
    BackendTrace.notice(
      phase: TracePhase.Embedding.spawnRuntimeReady.rawValue,
      context: lifecycleContext(),
      snapshot: .current()
    )
  }

  /// Hard cap on MLX's allocator cache. 2 GiB is large enough to retain
  /// the typical forward-pass intermediates across requests with similar
  /// shapes, and small enough to keep total footprint near the model
  /// weight plus working set.
  ///
  /// The value is calibrated against the BackendTrace data captured in
  /// the `Settle Duplicate-Load vs MLX-Cache` reproduction: without a
  /// cap, `mlx_cache` climbed from `4 KB` to `40 GB` over 80 seconds of
  /// indexing traffic; with the cap, it holds in a `2.09 GB - 2.18 GB`
  /// band. Silently lowering the value risks throughput; silently
  /// removing the call site reintroduces the leak.
  static var cacheLimitBytes: Int { configuredEmbeddingCacheLimitBytes() }

  public func shutdown() {
    guard runtime != nil else {
      return
    }
    BackendTrace.notice(
      phase: TracePhase.Embedding.shutdownPre.rawValue,
      context: lifecycleContext(),
      snapshot: .current()
    )
    runtime = nil
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
    guard let runtime else {
      throw NVEmbeddingRuntimeError.modelNotLoaded
    }
    BackendTrace.debug(
      phase: TracePhase.Embedding.requestPreTokenize.rawValue,
      context: requestContext(),
      snapshot: .current(),
      extras: ["input_count": "\(inputs.count)"]
    )
    let batch = tokenize(inputs: inputs, tokenizer: runtime.tokenizer)
    BackendTrace.debug(
      phase: TracePhase.Embedding.requestPostTokenize.rawValue,
      context: requestContext(),
      snapshot: .current(),
      extras: [
        "batch_size": "\(batch.stats.batchSize)",
        "max_seq_len": "\(batch.stats.maxSeqLen)",
        "total_tokens": "\(batch.stats.totalTokens)",
        "padding_ratio": String(format: "%.4f", batch.stats.paddingRatio),
      ]
    )
    BackendTrace.debug(
      phase: TracePhase.Embedding.requestPreForward.rawValue,
      context: requestContext(),
      snapshot: .current()
    )
    let hiddenStates = runtime.model(batch.inputIDs, attentionMask: batch.attentionMask)
    BackendTrace.debug(
      phase: TracePhase.Embedding.requestPostForward.rawValue,
      context: requestContext(),
      snapshot: .current()
    )
    let pooled = Self.poolHiddenStates(
      hiddenStates: hiddenStates,
      attentionMask: batch.attentionMask,
      metadata: metadata
    )
    BackendTrace.debug(
      phase: TracePhase.Embedding.requestPostPool.rawValue,
      context: requestContext(),
      snapshot: .current()
    )
    pooled.eval()
    BackendTrace.debug(
      phase: TracePhase.Embedding.requestPostEval.rawValue,
      context: requestContext(),
      snapshot: .current()
    )

    let batchCount = pooled.shape[0]
    var rows: [[Float]] = []
    rows.reserveCapacity(batchCount)
    for i in 0..<batchCount {
      rows.append(pooled[i].asArray(Float.self))
    }
    BackendTrace.debug(
      phase: TracePhase.Embedding.requestPreReturn.rawValue,
      context: requestContext(),
      snapshot: .current(),
      extras: ["row_count": "\(rows.count)"]
    )
    return rows
  }

  func tokenize(inputs: [String], tokenizer: any MLXLMCommon.Tokenizer) -> NVEmbeddingBatch {
    var encodedInputs = inputs.map { input in
      let encoded = tokenizer.encode(text: input, addSpecialTokens: true)
      if encoded.count > metadata.maxSequenceLength {
        return Array(encoded.prefix(metadata.maxSequenceLength))
      }
      return encoded
    }
    if encodedInputs.isEmpty {
      encodedInputs = [[]]
    }
    let maxLength = encodedInputs.reduce(into: 1) { currentMax, tokens in
      currentMax = max(currentMax, tokens.count)
    }
    var tokenRows: [Int] = []
    var maskRows: [Int32] = []
    tokenRows.reserveCapacity(encodedInputs.count * maxLength)
    maskRows.reserveCapacity(encodedInputs.count * maxLength)
    for tokens in encodedInputs {
      let padCount = maxLength - tokens.count
      switch metadata.paddingSide {
      case .left:
        tokenRows.append(contentsOf: Array(repeating: metadata.padTokenID, count: padCount))
        tokenRows.append(contentsOf: tokens)
        maskRows.append(contentsOf: Array(repeating: 0, count: padCount))
        maskRows.append(contentsOf: Array(repeating: 1, count: tokens.count))
      case .right:
        tokenRows.append(contentsOf: tokens)
        tokenRows.append(contentsOf: Array(repeating: metadata.padTokenID, count: padCount))
        maskRows.append(contentsOf: Array(repeating: 1, count: tokens.count))
        maskRows.append(contentsOf: Array(repeating: 0, count: padCount))
      }
    }
    let batchSize = encodedInputs.count
    let totalTokens = encodedInputs.reduce(0) { $0 + $1.count }
    let totalSlots = batchSize * maxLength
    let paddingRatio = totalSlots > 0 ? Double(totalSlots - totalTokens) / Double(totalSlots) : 0.0
    let stats = NVEmbeddingBatchStats(
      batchSize: batchSize,
      maxSeqLen: maxLength,
      totalTokens: totalTokens,
      paddingRatio: paddingRatio
    )
    return NVEmbeddingBatch(
      inputIDs: MLXArray(tokenRows).reshaped(encodedInputs.count, maxLength),
      attentionMask: MLXArray(maskRows).reshaped(encodedInputs.count, maxLength),
      stats: stats
    )
  }

  static func poolHiddenStates(
    hiddenStates: MLXArray,
    attentionMask: MLXArray,
    metadata: NVEmbeddingMetadata
  ) -> MLXArray {
    let mask = attentionMask.asType(hiddenStates.dtype)
    let expandedMask = mask.expandedDimensions(axes: [-1])
    let summed = sum(hiddenStates * expandedMask, axis: 1)
    let counts = MLX.maximum(
      sum(mask, axis: -1, keepDims: true),
      MLXArray(Float(1.0)).asType(hiddenStates.dtype)
    )
    var pooled = summed / counts
    if metadata.embeddingDimension < pooled.dim(-1) {
      pooled = pooled[0..., 0..<metadata.embeddingDimension]
    }
    return pooled.l2Normalized()
  }
}

struct NVEmbeddingBatch {
  let inputIDs: MLXArray
  let attentionMask: MLXArray
  let stats: NVEmbeddingBatchStats
}

struct NVEmbeddingBatchStats: Sendable {
  let batchSize: Int
  let maxSeqLen: Int
  let totalTokens: Int
  let paddingRatio: Double
}

private struct NVEmbeddingRuntime {
  let model: NVMistralBiDirectionalModel
  let tokenizer: any MLXLMCommon.Tokenizer
}

struct NVEmbeddingPoolingConfig: Decodable, Equatable, Sendable {
  let wordEmbeddingDimension: Int
  let poolingModeCLSToken: Bool
  let poolingModeMeanTokens: Bool
  let poolingModeMaxTokens: Bool
  let poolingModeLastToken: Bool
  let includePrompt: Bool

  var mode: NVEmbeddingPoolingMode {
    if poolingModeCLSToken {
      return .clsToken
    }
    if poolingModeMeanTokens {
      return .meanTokens
    }
    if poolingModeMaxTokens {
      return .maxTokens
    }
    if poolingModeLastToken {
      return .lastToken
    }
    return .meanTokens
  }

  enum CodingKeys: String, CodingKey {
    case wordEmbeddingDimension = "word_embedding_dimension"
    case poolingModeCLSToken = "pooling_mode_cls_token"
    case poolingModeMeanTokens = "pooling_mode_mean_tokens"
    case poolingModeMaxTokens = "pooling_mode_max_tokens"
    case poolingModeLastToken = "pooling_mode_lasttoken"
    case includePrompt = "include_prompt"
  }

  init(from decoder: Swift.Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    wordEmbeddingDimension = try container.decode(Int.self, forKey: .wordEmbeddingDimension)
    poolingModeCLSToken =
      try container.decodeIfPresent(Bool.self, forKey: .poolingModeCLSToken) ?? false
    poolingModeMeanTokens =
      try container.decodeIfPresent(Bool.self, forKey: .poolingModeMeanTokens) ?? false
    poolingModeMaxTokens =
      try container.decodeIfPresent(Bool.self, forKey: .poolingModeMaxTokens) ?? false
    poolingModeLastToken =
      try container.decodeIfPresent(Bool.self, forKey: .poolingModeLastToken) ?? false
    includePrompt = try container.decodeIfPresent(Bool.self, forKey: .includePrompt) ?? true
  }

  static func load(modelID: String, modelDir: String) throws -> NVEmbeddingPoolingConfig {
    let path = "\(modelDir)/1_Pooling/config.json"
    do {
      let data = try Data(contentsOf: URL(fileURLWithPath: path))
      return try JSONDecoder().decode(NVEmbeddingPoolingConfig.self, from: data)
    } catch {
      throw EmbeddingBackendSelectionError.invalidConfig(modelID: modelID, path: path)
    }
  }
}

struct NVSentenceBertConfig: Decodable, Equatable, Sendable {
  let maxSequenceLength: Int

  enum CodingKeys: String, CodingKey {
    case maxSequenceLength = "max_seq_length"
  }

  static func load(modelID: String, modelDir: String) throws -> NVSentenceBertConfig {
    let path = "\(modelDir)/sentence_bert_config.json"
    do {
      let data = try Data(contentsOf: URL(fileURLWithPath: path))
      return try JSONDecoder().decode(NVSentenceBertConfig.self, from: data)
    } catch {
      throw EmbeddingBackendSelectionError.invalidConfig(modelID: modelID, path: path)
    }
  }
}

struct NVTokenizerConfig: Decodable, Equatable, Sendable {
  let padToken: String?
  let paddingSide: NVEmbeddingPaddingSide

  var padTokenID: Int {
    if padToken == "<unk>" {
      return 0
    }
    if padToken == "<s>" {
      return 1
    }
    return 2
  }

  enum CodingKeys: String, CodingKey {
    case padToken = "pad_token"
    case paddingSide = "padding_side"
  }

  static func load(modelDir: String) -> NVTokenizerConfig {
    let path = "\(modelDir)/tokenizer_config.json"
    guard
      let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
      let config = try? JSONDecoder().decode(NVTokenizerConfig.self, from: data)
    else {
      return NVTokenizerConfig(padToken: "</s>", paddingSide: .right)
    }
    return config
  }
}
