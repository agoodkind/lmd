//
//  NVEmbeddingBF16BisectTests.swift
//  SwiftLMEmbedTests
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-06-11.
//  Copyright © 2026, all rights reserved.
//
//  Diagnostic bisect for the bf16 non-finite embedding failure. The same
//  math (architecture, weights, shapes, pooling) is finite in official MLX
//  Python, so this test walks lmd's own Swift forward op by op against the
//  parked bf16 weights and names the first operation that produces a
//  non-finite value. The shapes are the exact production failures: the
//  packed groups of the first synthetic bench batch and the two-long-rows
//  shape that broke live ingest.
//
//  The test loads the local 14 GB bf16 weight set and skips when it is not
//  present, so CI and machines without the model stay green. It runs in the
//  test process only and never contacts the running daemon.
//

import MLX
import MLXHuggingFace
import MLXLMCommon
import Nimble
import SwiftLMCore
import Tokenizers
import XCTest

@testable import SwiftLMEmbed

final class NVEmbeddingBF16BisectTests: XCTestCase {
  private static let bf16ModelPath = NSString(
    string: "~/.lmstudio/models/nvidia/NV-EmbedCode-7b-v1-bf16"
  ).expandingTildeInPath

  /// One finiteness probe. Returns the failure description, nil when finite.
  private func probe(_ name: String, _ tensor: MLXArray) -> String? {
    let hasNaN = MLX.any(MLX.isNaN(tensor))
    let hasInf = MLX.any(MLX.isInf(tensor))
    let maxAbs = MLX.abs(tensor).max()
    eval(hasNaN, hasInf, maxAbs)
    let report = "\(name): max|x|=\(maxAbs.item(Float.self))"
    print(report)
    if !hasNaN.item(Bool.self) && !hasInf.item(Bool.self) {
      return nil
    }
    return
      "first non-finite at \(name) (nan=\(hasNaN.item(Bool.self)) inf=\(hasInf.item(Bool.self)))"
  }

  func testBF16ForwardBisectOnProductionFailingShapes() async throws {
    guard ProcessInfo.processInfo.environment["LMD_BF16_BISECT"] == "1" else {
      throw XCTSkip("set LMD_BF16_BISECT=1 to run the bf16 diagnostic (loads 14 GB, minutes)")
    }
    guard FileManager.default.fileExists(atPath: Self.bf16ModelPath) else {
      throw XCTSkip("bf16 weight set not present at \(Self.bf16ModelPath)")
    }
    // MLX resolves default.metallib relative to cwd at device init, which the
    // weight load below triggers, so the whole test body runs from the build
    // products directory.
    let originalPath = FileManager.default.currentDirectoryPath
    let metallibDirectory = try bisectRepoRoot()
      .appendingPathComponent("Products", isDirectory: true)
      .appendingPathComponent("Build", isDirectory: true)
      .appendingPathComponent("Debug", isDirectory: true)
    guard
      FileManager.default.fileExists(
        atPath: metallibDirectory.appendingPathComponent("default.metallib").path
      ),
      FileManager.default.changeCurrentDirectoryPath(metallibDirectory.path)
    else {
      throw XCTSkip("MLX default.metallib not reachable under \(metallibDirectory.path)")
    }
    defer {
      FileManager.default.changeCurrentDirectoryPath(originalPath)
    }

    let modelDirectory = URL(fileURLWithPath: Self.bf16ModelPath)
    let configData = try Data(contentsOf: modelDirectory.appendingPathComponent("config.json"))
    let configuration = try JSONDecoder().decode(
      NVMistralBiDirectionalConfiguration.self,
      from: configData
    )
    let model = NVMistralBiDirectionalModel(configuration)
    try loadWeights(modelDirectory: modelDirectory, model: model)
    let tokenizer = try await #huggingFaceTokenizerLoader().load(from: modelDirectory)

    func encodedRepeats(_ repeats: Int) -> [Int] {
      let encoded = tokenizer.encode(text: String(repeating: "func ", count: repeats))
      return Array(encoded.prefix(4_096))
    }

    // The production failure matrix. Token targets reproduce the packed
    // groups of the first failing bench batch (56 x ~358 and 8 x ~848) and
    // the two-long-rows ingest failure (2 x ~727), plus the passing canary
    // (2 x ~1450) for contrast.
    let shapes: [(name: String, rows: [[Int]])] = [
      ("group 8x848", Array(repeating: encodedRepeats(846), count: 8)),
      ("group 56x358", Array(repeating: encodedRepeats(356), count: 56)),
      ("ingest 2x727", Array(repeating: encodedRepeats(725), count: 2)),
      ("canary 2x1450", Array(repeating: encodedRepeats(1_448), count: 2)),
    ]

    var failures: [String] = []
    for shape in shapes {
      print("=== bisecting \(shape.name) ===")
      if let failure = bisectForward(model: model, encodedRows: shape.rows) {
        failures.append("\(shape.name): \(failure)")
      }
    }

    expect(failures).to(
      beEmpty(),
      description: "bf16 forward produced non-finite values: \(failures)"
    )
  }

  /// Mirrors NVMistralBiDirectionalModel.callAsFunction plus the backend's
  /// padding and pooling, with a finiteness probe after every operation. The
  /// layer objects, mask construction, RoPE instances, and SDPA call are the
  /// production ones, so a divergence from the clean Python run isolates the
  /// Swift or kernel layer that owns the bug.
  private func bisectForward(
    model: NVMistralBiDirectionalModel,
    encodedRows: [[Int]]
  ) -> String? {
    let metadata = NVEmbeddingMetadata(
      modelType: "mistralbidirectional",
      architecture: "MistralBiDirectionalModel",
      embeddingDimension: 4_096,
      maxSequenceLength: 4_096,
      poolingMode: .meanTokens,
      includePrompt: true,
      padTokenID: 2,
      paddingSide: .left
    )
    let batch = NVEmbeddingBackend.padEncoded(encodedRows, metadata: metadata)
    let inner = model.model

    var hidden = inner.embedTokens(batch.inputIDs)
    if let bad = probe("embed", hidden) { return bad }

    let mask = NVMistralBiDirectionalModelInner.bidirectionalPaddingMask(
      attentionMask: batch.attentionMask,
      dtype: hidden.dtype
    )

    for (index, layer) in inner.layers.enumerated() {
      let attention = layer.attention
      let normed = layer.inputLayerNorm(hidden)
      if let bad = probe("layer\(index).attn_norm", normed) { return bad }

      let batchSize = normed.dim(0)
      let sequenceLength = normed.dim(1)
      var queries = attention.queryProjection(normed)
        .reshaped(batchSize, sequenceLength, attention.attentionHeads, attention.headDimension)
        .transposed(0, 2, 1, 3)
      var keys = attention.keyProjection(normed)
        .reshaped(batchSize, sequenceLength, attention.keyValueHeads, attention.headDimension)
        .transposed(0, 2, 1, 3)
      let values = attention.valueProjection(normed)
        .reshaped(batchSize, sequenceLength, attention.keyValueHeads, attention.headDimension)
        .transposed(0, 2, 1, 3)
      if let bad = probe("layer\(index).qkv", queries + 0 * queries) { return bad }

      queries = attention.rope(queries, offset: 0)
      keys = attention.rope(keys, offset: 0)
      if let bad = probe("layer\(index).rope_q", queries) { return bad }
      if let bad = probe("layer\(index).rope_k", keys) { return bad }

      let attended = MLXFast.scaledDotProductAttention(
        queries: queries,
        keys: keys,
        values: values,
        scale: attention.scale,
        mask: mask
      )
      if let bad = probe("layer\(index).sdpa", attended) { return bad }

      let attnOut = attention.outputProjection(
        attended.transposed(0, 2, 1, 3).reshaped(batchSize, sequenceLength, -1)
      )
      if let bad = probe("layer\(index).o_proj", attnOut) { return bad }

      hidden = hidden + attnOut
      let postNorm = layer.postAttentionLayerNorm(hidden)
      let mlpOut = layer.mlp(postNorm)
      if let bad = probe("layer\(index).mlp", mlpOut) { return bad }
      hidden = hidden + mlpOut
      if let bad = probe("layer\(index).hidden", hidden) { return bad }
    }

    hidden = inner.norm(hidden)
    if let bad = probe("final_norm", hidden) { return bad }

    let pooled = NVEmbeddingBackend.poolHiddenStates(
      hiddenStates: hidden,
      attentionMask: batch.attentionMask,
      metadata: metadata
    )
    pooled.eval()
    if let bad = probe("pooled", pooled) { return bad }
    return nil
  }

  /// The fresh-process bisect passes, so this method reproduces the host's
  /// long-running state instead: the production MLX cache cap plus repeated
  /// mixed-shape forwards, which recycles allocator buffers the way hours of
  /// ingest traffic does. A non-finite result here, absent above, isolates
  /// the failure to allocator-state-dependent kernel behavior.
  func testBF16RepeatedForwardsUnderTightCacheLimit() async throws {
    guard ProcessInfo.processInfo.environment["LMD_BF16_BISECT"] == "1" else {
      throw XCTSkip("set LMD_BF16_BISECT=1 to run the bf16 diagnostic (loads 14 GB, minutes)")
    }
    guard FileManager.default.fileExists(atPath: Self.bf16ModelPath) else {
      throw XCTSkip("bf16 weight set not present at \(Self.bf16ModelPath)")
    }
    let originalPath = FileManager.default.currentDirectoryPath
    let metallibDirectory = try bisectRepoRoot()
      .appendingPathComponent("Products", isDirectory: true)
      .appendingPathComponent("Build", isDirectory: true)
      .appendingPathComponent("Debug", isDirectory: true)
    guard
      FileManager.default.fileExists(
        atPath: metallibDirectory.appendingPathComponent("default.metallib").path
      ),
      FileManager.default.changeCurrentDirectoryPath(metallibDirectory.path)
    else {
      throw XCTSkip("MLX default.metallib not reachable under \(metallibDirectory.path)")
    }
    defer {
      FileManager.default.changeCurrentDirectoryPath(originalPath)
    }

    let modelDirectory = URL(fileURLWithPath: Self.bf16ModelPath)
    let configData = try Data(contentsOf: modelDirectory.appendingPathComponent("config.json"))
    let configuration = try JSONDecoder().decode(
      NVMistralBiDirectionalConfiguration.self,
      from: configData
    )
    let model = NVMistralBiDirectionalModel(configuration)
    try loadWeights(modelDirectory: modelDirectory, model: model)
    let tokenizer = try await #huggingFaceTokenizerLoader().load(from: modelDirectory)

    func encodedRepeats(_ repeats: Int) -> [Int] {
      let encoded = tokenizer.encode(text: String(repeating: "func ", count: repeats))
      return Array(encoded.prefix(4_096))
    }

    let metadata = NVEmbeddingMetadata(
      modelType: "mistralbidirectional",
      architecture: "MistralBiDirectionalModel",
      embeddingDimension: 4_096,
      maxSequenceLength: 4_096,
      poolingMode: .meanTokens,
      includePrompt: true,
      padTokenID: 2,
      paddingSide: .left
    )
    let shapes: [(name: String, rows: [[Int]])] = [
      ("group 8x848", Array(repeating: encodedRepeats(846), count: 8)),
      ("group 56x358", Array(repeating: encodedRepeats(356), count: 56)),
      ("ingest 2x727", Array(repeating: encodedRepeats(725), count: 2)),
      (
        "mixed 4",
        [
          encodedRepeats(4), encodedRepeats(846), encodedRepeats(60), encodedRepeats(356),
        ]
      ),
    ]

    // The production cap at the time of every observed failure.
    let productionCacheLimit = 2 * 1_024 * 1_024 * 1_024
    let previousLimit = Memory.cacheLimit
    Memory.cacheLimit = productionCacheLimit
    defer { Memory.cacheLimit = previousLimit }

    var failures: [String] = []
    let iterations = 10
    for iteration in 0..<iterations {
      for shape in shapes {
        let batch = NVEmbeddingBackend.padEncoded(shape.rows, metadata: metadata)
        let hidden = model(batch.inputIDs, attentionMask: batch.attentionMask)
        let pooled = NVEmbeddingBackend.poolHiddenStates(
          hiddenStates: hidden,
          attentionMask: batch.attentionMask,
          metadata: metadata
        )
        let hasNaN = MLX.any(MLX.isNaN(pooled))
        let hasInf = MLX.any(MLX.isInf(pooled))
        eval(hasNaN, hasInf)
        let snapshot = GPU.snapshot()
        print(
          "iter \(iteration) \(shape.name): nan=\(hasNaN.item(Bool.self)) "
            + "inf=\(hasInf.item(Bool.self)) cache=\(snapshot.cacheMemory)"
        )
        if hasNaN.item(Bool.self) || hasInf.item(Bool.self) {
          failures.append("iteration \(iteration) \(shape.name)")
        }
      }
    }
    expect(failures).to(
      beEmpty(),
      description: "state-dependent non-finite outputs: \(failures)"
    )
  }

  private func bisectRepoRoot() throws -> URL {
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
}
