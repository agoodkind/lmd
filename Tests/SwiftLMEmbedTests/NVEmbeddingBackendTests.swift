//
//  NVEmbeddingBackendTests.swift
//  SwiftLMEmbedTests
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-05-17.
//  Copyright © 2026, all rights reserved.
//

import MLX
import SwiftLMCore
import XCTest

@testable import SwiftLMEmbed

final class NVEmbeddingBackendTests: XCTestCase {
  func testNVIDIAMistralBidirectionalMetadataSelectsNVBackend() throws {
    let modelDirectory = try writeModel(
      config: nvidiaConfig(),
      pooling: poolingConfig(dimension: 4096, includePrompt: true),
      sentence: sentenceConfig(maxSequenceLength: 4096),
      tokenizer: tokenizerConfig(padToken: "</s>", paddingSide: .left)
    )
    let descriptor = descriptor(path: modelDirectory)

    let family = try EmbeddingBackendSelector.select(descriptor: descriptor)

    guard case .nvidiaMistralBidirectional(let metadata) = family else {
      XCTFail("expected NVIDIA backend, got \(family)")
      return
    }
    XCTAssertEqual(metadata.modelType, "mistralbidirectional")
    XCTAssertEqual(metadata.architecture, "MistralBiDirectionalModel")
    XCTAssertEqual(metadata.embeddingDimension, 4096)
    XCTAssertEqual(metadata.maxSequenceLength, 4096)
    XCTAssertEqual(metadata.poolingMode, .meanTokens)
    XCTAssertTrue(metadata.includePrompt)
    XCTAssertEqual(metadata.padTokenID, 2)
    XCTAssertEqual(metadata.paddingSide, .left)
  }

  func testExistingMLXEmbedderMetadataSelectsMLXBackend() throws {
    let modelDirectory = try writeModel(
      config: TestModelConfig(
        architectures: ["XLMRobertaModel"],
        modelType: "xlm-roberta"
      )
    )
    let descriptor = descriptor(path: modelDirectory)

    let family = try EmbeddingBackendSelector.select(descriptor: descriptor)

    XCTAssertEqual(family, .mlx)
  }

  func testUnsupportedEmbeddingMetadataFailsClearly() throws {
    let modelDirectory = try writeModel(
      config: TestModelConfig(
        architectures: ["CustomEmbeddingModel"],
        modelType: "custom_embed"
      )
    )
    let descriptor = descriptor(path: modelDirectory)

    XCTAssertThrowsError(try EmbeddingBackendSelector.select(descriptor: descriptor)) { error in
      guard
        case EmbeddingBackendSelectionError.unsupportedEmbeddingBackend(
          let modelID,
          let modelType,
          let architectures
        ) = error
      else {
        XCTFail("unexpected error \(error)")
        return
      }
      XCTAssertEqual(modelID, descriptor.id)
      XCTAssertEqual(modelType, "custom_embed")
      XCTAssertEqual(architectures, ["CustomEmbeddingModel"])
      XCTAssertTrue(String(describing: error).contains("unsupported embedding backend"))
    }
  }

  func testMetadataParsingReadsPoolingPromptAndSequenceLength() throws {
    let modelDirectory = try writeModel(
      config: nvidiaConfig(),
      pooling: poolingConfig(dimension: 128, includePrompt: false),
      sentence: sentenceConfig(maxSequenceLength: 512),
      tokenizer: tokenizerConfig(padToken: "<unk>", paddingSide: .right)
    )
    let metadata = try NVEmbeddingMetadata.load(
      modelID: modelDirectory,
      modelDir: modelDirectory
    )

    XCTAssertEqual(metadata.embeddingDimension, 128)
    XCTAssertEqual(metadata.maxSequenceLength, 512)
    XCTAssertEqual(metadata.poolingMode, .meanTokens)
    XCTAssertFalse(metadata.includePrompt)
    XCTAssertEqual(metadata.padTokenID, 0)
    XCTAssertEqual(metadata.paddingSide, .right)
  }

  func testMeanPoolingExcludesPaddingAndNormalizes() throws {
    try withMLXMetallib {
      let hiddenStates = MLXArray([
        3.0 as Float, 4.0,
        9.0, 12.0,
        100.0, 100.0,
        5.0, 0.0,
        100.0, 100.0,
        100.0, 100.0,
      ]).reshaped(2, 3, 2)
      let attentionMask = MLXArray([
        1 as Int32, 1, 0,
        1, 0, 0,
      ]).reshaped(2, 3)
      let metadata = metadata(dimension: 2)

      let pooled = NVEmbeddingBackend.poolHiddenStates(
        hiddenStates: hiddenStates,
        attentionMask: attentionMask,
        metadata: metadata
      )
      pooled.eval()

      XCTAssertEqual(pooled.shape, [2, 2])
      assertVector(pooled[0].asArray(Float.self), approximately: [0.6, 0.8])
      assertVector(pooled[1].asArray(Float.self), approximately: [1.0, 0.0])
    }
  }

  func testTinyMistralAdapterReturnsNormalizedBatchVectors() throws {
    try withMLXMetallib {
      let configuration = NVMistralBiDirectionalConfiguration(
        hiddenSize: 8,
        hiddenLayers: 1,
        intermediateSize: 16,
        attentionHeads: 2,
        keyValueHeads: 1,
        vocabularySize: 32
      )
      let model = NVMistralBiDirectionalModel(configuration)
      let inputIDs = MLXArray([
        1, 3, 4,
        1, 5, 2,
      ]).reshaped(2, 3)
      let attentionMask = MLXArray([
        1 as Int32, 1, 1,
        1, 1, 0,
      ]).reshaped(2, 3)
      let hiddenStates = model(inputIDs, attentionMask: attentionMask)
      let pooled = NVEmbeddingBackend.poolHiddenStates(
        hiddenStates: hiddenStates,
        attentionMask: attentionMask,
        metadata: metadata(dimension: 8)
      )
      pooled.eval()

      XCTAssertEqual(pooled.shape, [2, 8])
      XCTAssertEqual(pooled[0].asArray(Float.self).count, 8)
      XCTAssertEqual(pooled[1].asArray(Float.self).count, 8)
      XCTAssertEqual(l2Norm(pooled[0].asArray(Float.self)), 1.0, accuracy: 0.0001)
      XCTAssertEqual(l2Norm(pooled[1].asArray(Float.self)), 1.0, accuracy: 0.0001)
    }
  }

  private func descriptor(path: String) -> ModelDescriptor {
    ModelDescriptor(
      id: path,
      displayName: "NV-EmbedCode-7b-v1",
      path: path,
      slug: "nvidia/NV-EmbedCode-7b-v1",
      kind: .embedding
    )
  }

  private func metadata(dimension: Int) -> NVEmbeddingMetadata {
    NVEmbeddingMetadata(
      modelType: "mistralbidirectional",
      architecture: "MistralBiDirectionalModel",
      embeddingDimension: dimension,
      maxSequenceLength: 16,
      poolingMode: .meanTokens,
      includePrompt: true,
      padTokenID: 2,
      paddingSide: .right
    )
  }

  private func writeModel(
    config: TestModelConfig,
    pooling: TestPoolingConfig? = nil,
    sentence: TestSentenceConfig? = nil,
    tokenizer: TestTokenizerConfig? = nil
  ) throws -> String {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("lmd-nv-embedding-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try writeJSON(config, to: root.appendingPathComponent("config.json"))
    try writeJSON([TestModuleConfig](), to: root.appendingPathComponent("modules.json"))
    if let pooling {
      let poolingDirectory = root.appendingPathComponent("1_Pooling", isDirectory: true)
      try FileManager.default.createDirectory(
        at: poolingDirectory, withIntermediateDirectories: true)
      try writeJSON(pooling, to: poolingDirectory.appendingPathComponent("config.json"))
    }
    if let sentence {
      try writeJSON(sentence, to: root.appendingPathComponent("sentence_bert_config.json"))
    }
    if let tokenizer {
      try writeJSON(tokenizer, to: root.appendingPathComponent("tokenizer_config.json"))
    }
    return root.path
  }

  private func writeJSON<T: Encodable>(_ value: T, to url: URL) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(value)
    try data.write(to: url, options: [.atomic])
  }

  private func nvidiaConfig() -> TestModelConfig {
    TestModelConfig(
      architectures: ["MistralBiDirectionalModel"],
      autoMap: TestAutoMap(autoModel: "bidirectional_models.MistralBiDirectionalModel"),
      modelType: "mistralbidirectional"
    )
  }

  private func poolingConfig(dimension: Int, includePrompt: Bool) -> TestPoolingConfig {
    TestPoolingConfig(
      wordEmbeddingDimension: dimension,
      poolingModeCLSToken: false,
      poolingModeMeanTokens: true,
      poolingModeMaxTokens: false,
      poolingModeLastToken: false,
      includePrompt: includePrompt
    )
  }

  private func sentenceConfig(maxSequenceLength: Int) -> TestSentenceConfig {
    TestSentenceConfig(maxSequenceLength: maxSequenceLength)
  }

  private func tokenizerConfig(
    padToken: String,
    paddingSide: NVEmbeddingPaddingSide
  ) -> TestTokenizerConfig {
    TestTokenizerConfig(padToken: padToken, paddingSide: paddingSide.rawValue)
  }

  private func withMLXMetallib(_ body: () throws -> Void) throws {
    let originalPath = FileManager.default.currentDirectoryPath
    let metallibDirectory = try repoRoot()
      .appendingPathComponent("Products", isDirectory: true)
      .appendingPathComponent("Build", isDirectory: true)
      .appendingPathComponent("Debug", isDirectory: true)
    let metallibPath = metallibDirectory.appendingPathComponent("default.metallib").path
    guard FileManager.default.fileExists(atPath: metallibPath) else {
      throw XCTSkip("MLX default.metallib not found at \(metallibPath); run make build first")
    }
    guard FileManager.default.changeCurrentDirectoryPath(metallibDirectory.path) else {
      throw XCTSkip("could not switch to MLX metallib directory \(metallibDirectory.path)")
    }
    defer {
      FileManager.default.changeCurrentDirectoryPath(originalPath)
    }
    try body()
  }

  private func repoRoot() throws -> URL {
    var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    while directory.path != "/" {
      if FileManager.default.fileExists(
        atPath: directory.appendingPathComponent("Package.swift").path
      ) {
        return directory
      }
      directory = directory.deletingLastPathComponent()
    }
    throw XCTSkip("could not locate Package.swift above \(#filePath)")
  }

  private func assertVector(
    _ actual: [Float],
    approximately expected: [Float],
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    XCTAssertEqual(actual.count, expected.count, file: file, line: line)
    for (actualValue, expectedValue) in zip(actual, expected) {
      XCTAssertEqual(actualValue, expectedValue, accuracy: 0.0001, file: file, line: line)
    }
  }

  private func l2Norm(_ values: [Float]) -> Float {
    let sumOfSquares = values.reduce(Float(0)) { partialResult, value in
      partialResult + value * value
    }
    return sqrt(sumOfSquares)
  }
}

private struct TestModelConfig: Encodable {
  let architectures: [String]
  let autoMap: TestAutoMap?
  let modelType: String

  init(
    architectures: [String],
    autoMap: TestAutoMap? = nil,
    modelType: String
  ) {
    self.architectures = architectures
    self.autoMap = autoMap
    self.modelType = modelType
  }

  enum CodingKeys: String, CodingKey {
    case architectures
    case autoMap = "auto_map"
    case modelType = "model_type"
  }
}

private struct TestAutoMap: Encodable {
  let autoModel: String

  enum CodingKeys: String, CodingKey {
    case autoModel = "AutoModel"
  }
}

private struct TestModuleConfig: Encodable {}

private struct TestPoolingConfig: Encodable {
  let wordEmbeddingDimension: Int
  let poolingModeCLSToken: Bool
  let poolingModeMeanTokens: Bool
  let poolingModeMaxTokens: Bool
  let poolingModeLastToken: Bool
  let includePrompt: Bool

  enum CodingKeys: String, CodingKey {
    case wordEmbeddingDimension = "word_embedding_dimension"
    case poolingModeCLSToken = "pooling_mode_cls_token"
    case poolingModeMeanTokens = "pooling_mode_mean_tokens"
    case poolingModeMaxTokens = "pooling_mode_max_tokens"
    case poolingModeLastToken = "pooling_mode_lasttoken"
    case includePrompt = "include_prompt"
  }
}

private struct TestSentenceConfig: Encodable {
  let maxSequenceLength: Int

  enum CodingKeys: String, CodingKey {
    case maxSequenceLength = "max_seq_length"
  }
}

private struct TestTokenizerConfig: Encodable {
  let padToken: String
  let paddingSide: String

  enum CodingKeys: String, CodingKey {
    case padToken = "pad_token"
    case paddingSide = "padding_side"
  }
}
