//
//  NVMistralBiDirectionalModel.swift
//  SwiftLMEmbed
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-05-17.
//  Copyright © 2026, all rights reserved.
//

import AppLogger
import Foundation
import MLX
import MLXLMCommon
import MLXNN

private let log = AppLogger.logger(category: "NVMistralBiDirectionalModel")

final class NVMistralBiDirectionalAttention: Module {
  let attentionHeads: Int
  let keyValueHeads: Int
  let headDimension: Int
  let scale: Float

  @ModuleInfo(key: "q_proj") var queryProjection: Linear
  @ModuleInfo(key: "k_proj") var keyProjection: Linear
  @ModuleInfo(key: "v_proj") var valueProjection: Linear
  @ModuleInfo(key: "o_proj") var outputProjection: Linear

  let rope: RoPE

  init(_ configuration: NVMistralBiDirectionalConfiguration) {
    attentionHeads = configuration.attentionHeads
    keyValueHeads = configuration.keyValueHeads
    headDimension = configuration.hiddenSize / configuration.attentionHeads
    scale = pow(Float(headDimension), -0.5)

    _queryProjection.wrappedValue = Linear(
      configuration.hiddenSize,
      attentionHeads * headDimension,
      bias: false
    )
    _keyProjection.wrappedValue = Linear(
      configuration.hiddenSize,
      keyValueHeads * headDimension,
      bias: false
    )
    _valueProjection.wrappedValue = Linear(
      configuration.hiddenSize,
      keyValueHeads * headDimension,
      bias: false
    )
    _outputProjection.wrappedValue = Linear(
      attentionHeads * headDimension,
      configuration.hiddenSize,
      bias: false
    )
    rope = RoPE(
      dimensions: headDimension,
      traditional: false,
      base: configuration.ropeTheta
    )
  }

  func callAsFunction(
    _ hiddenStates: MLXArray,
    mask: MLXFast.ScaledDotProductAttentionMaskMode
  ) -> MLXArray {
    let batchSize = hiddenStates.dim(0)
    let sequenceLength = hiddenStates.dim(1)

    var queries = queryProjection(hiddenStates)
    var keys = keyProjection(hiddenStates)
    var values = valueProjection(hiddenStates)

    queries =
      queries
      .reshaped(batchSize, sequenceLength, attentionHeads, headDimension)
      .transposed(0, 2, 1, 3)
    keys =
      keys
      .reshaped(batchSize, sequenceLength, keyValueHeads, headDimension)
      .transposed(0, 2, 1, 3)
    values =
      values
      .reshaped(batchSize, sequenceLength, keyValueHeads, headDimension)
      .transposed(0, 2, 1, 3)

    queries = rope(queries, offset: 0)
    keys = rope(keys, offset: 0)

    let attended = MLXFast.scaledDotProductAttention(
      queries: queries,
      keys: keys,
      values: values,
      scale: scale,
      mask: mask
    )
    let output =
      attended
      .transposed(0, 2, 1, 3)
      .reshaped(batchSize, sequenceLength, -1)
    return outputProjection(output)
  }
}

final class NVMistralBiDirectionalMLP: Module, UnaryLayer {
  @ModuleInfo(key: "gate_proj") var gateProjection: Linear
  @ModuleInfo(key: "up_proj") var upProjection: Linear
  @ModuleInfo(key: "down_proj") var downProjection: Linear

  init(_ configuration: NVMistralBiDirectionalConfiguration) {
    _gateProjection.wrappedValue = Linear(
      configuration.hiddenSize,
      configuration.intermediateSize,
      bias: false
    )
    _upProjection.wrappedValue = Linear(
      configuration.hiddenSize,
      configuration.intermediateSize,
      bias: false
    )
    _downProjection.wrappedValue = Linear(
      configuration.intermediateSize,
      configuration.hiddenSize,
      bias: false
    )
  }

  func callAsFunction(_ hiddenStates: MLXArray) -> MLXArray {
    downProjection(silu(gateProjection(hiddenStates)) * upProjection(hiddenStates))
  }
}

final class NVMistralBiDirectionalTransformerBlock: Module {
  @ModuleInfo(key: "self_attn") var attention: NVMistralBiDirectionalAttention
  @ModuleInfo(key: "mlp") var mlp: NVMistralBiDirectionalMLP
  @ModuleInfo(key: "input_layernorm") var inputLayerNorm: RMSNorm
  @ModuleInfo(key: "post_attention_layernorm") var postAttentionLayerNorm: RMSNorm

  init(_ configuration: NVMistralBiDirectionalConfiguration) {
    _attention.wrappedValue = NVMistralBiDirectionalAttention(configuration)
    _mlp.wrappedValue = NVMistralBiDirectionalMLP(configuration)
    _inputLayerNorm.wrappedValue = RMSNorm(
      dimensions: configuration.hiddenSize,
      eps: configuration.rmsNormEpsilon
    )
    _postAttentionLayerNorm.wrappedValue = RMSNorm(
      dimensions: configuration.hiddenSize,
      eps: configuration.rmsNormEpsilon
    )
  }

  func callAsFunction(
    _ hiddenStates: MLXArray,
    mask: MLXFast.ScaledDotProductAttentionMaskMode
  ) -> MLXArray {
    let attentionOutput = attention(inputLayerNorm(hiddenStates), mask: mask)
    let attentionResidual = hiddenStates + attentionOutput
    let mlpOutput = mlp(postAttentionLayerNorm(attentionResidual))
    return attentionResidual + mlpOutput
  }
}

final class NVMistralBiDirectionalModelInner: Module {
  @ModuleInfo(key: "embed_tokens") var embedTokens: Embedding
  let layers: [NVMistralBiDirectionalTransformerBlock]
  let norm: RMSNorm

  init(_ configuration: NVMistralBiDirectionalConfiguration) {
    _embedTokens.wrappedValue = Embedding(
      embeddingCount: configuration.vocabularySize,
      dimensions: configuration.hiddenSize
    )
    layers = (0..<configuration.hiddenLayers).map { _ in
      NVMistralBiDirectionalTransformerBlock(configuration)
    }
    norm = RMSNorm(
      dimensions: configuration.hiddenSize,
      eps: configuration.rmsNormEpsilon
    )
  }

  func callAsFunction(_ inputIDs: MLXArray, attentionMask: MLXArray) -> MLXArray {
    var hiddenStates = embedTokens(inputIDs)
    let mask = Self.bidirectionalPaddingMask(
      attentionMask: attentionMask,
      dtype: hiddenStates.dtype
    )
    for layer in layers {
      hiddenStates = layer(hiddenStates, mask: mask)
    }
    return norm(hiddenStates)
  }

  static func bidirectionalPaddingMask(
    attentionMask: MLXArray,
    dtype: DType
  ) -> MLXFast.ScaledDotProductAttentionMaskMode {
    let keyPaddingMask =
      (attentionMask .== MLXArray(Int32(0)))
      .asType(dtype)
      .expandedDimensions(axes: [1, 2])
      * MLXArray(Float(-1e9)).asType(dtype)
    return .array(keyPaddingMask)
  }
}

final class NVMistralBiDirectionalModel: Module, BaseLanguageModel {
  @ModuleInfo(key: "model") var model: NVMistralBiDirectionalModelInner

  init(_ configuration: NVMistralBiDirectionalConfiguration) {
    _model.wrappedValue = NVMistralBiDirectionalModelInner(configuration)
  }

  func callAsFunction(_ inputIDs: MLXArray, attentionMask: MLXArray) -> MLXArray {
    model(inputIDs, attentionMask: attentionMask)
  }

  func sanitize(weights: [String: MLXArray]) -> [String: MLXArray] {
    var sanitized: [String: MLXArray] = [:]
    for (key, value) in weights {
      if key.contains("self_attn.rotary_emb.inv_freq") {
        continue
      }
      var sanitizedKey = key
      if !sanitizedKey.hasPrefix("model.") {
        sanitizedKey = "model.\(sanitizedKey)"
      }
      sanitized[sanitizedKey] = value
    }
    log.debug("nv_mistral.weights_sanitized count=\(sanitized.count, privacy: .public)")
    return sanitized
  }
}

struct NVMistralBiDirectionalConfiguration: Decodable, Equatable, Sendable {
  let hiddenSize: Int
  let hiddenLayers: Int
  let intermediateSize: Int
  let attentionHeads: Int
  let keyValueHeads: Int
  let rmsNormEpsilon: Float
  let ropeTheta: Float
  let vocabularySize: Int

  enum CodingKeys: String, CodingKey {
    case hiddenSize = "hidden_size"
    case hiddenLayers = "num_hidden_layers"
    case intermediateSize = "intermediate_size"
    case attentionHeads = "num_attention_heads"
    case keyValueHeads = "num_key_value_heads"
    case rmsNormEpsilon = "rms_norm_eps"
    case ropeTheta = "rope_theta"
    case vocabularySize = "vocab_size"
  }

  init(
    hiddenSize: Int,
    hiddenLayers: Int,
    intermediateSize: Int,
    attentionHeads: Int,
    keyValueHeads: Int,
    rmsNormEpsilon: Float = 1e-5,
    ropeTheta: Float = 10_000,
    vocabularySize: Int
  ) {
    self.hiddenSize = hiddenSize
    self.hiddenLayers = hiddenLayers
    self.intermediateSize = intermediateSize
    self.attentionHeads = attentionHeads
    self.keyValueHeads = keyValueHeads
    self.rmsNormEpsilon = rmsNormEpsilon
    self.ropeTheta = ropeTheta
    self.vocabularySize = vocabularySize
  }
}
