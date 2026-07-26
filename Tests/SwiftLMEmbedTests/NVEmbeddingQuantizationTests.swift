//
//  NVEmbeddingQuantizationTests.swift
//  SwiftLMEmbedTests
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-07-25.
//  Copyright © 2026, all rights reserved.
//

import MLX
import MLXLMCommon
import MLXNN
import Nimble
import XCTest

@testable import SwiftLMEmbed

private let expectedGroupSize = 32
private let expectedBits = 8
private let wrongGroupSize = 64
private let wrongBits = 4
private let testLayerWidth = 32

// MARK: - NVEmbeddingQuantizationTests

final class NVEmbeddingQuantizationTests: XCTestCase {
  func testConfigurationWithoutQuantizationBlockIsNil() throws {
    let configuration = try decodeConfiguration()

    try NVEmbeddingQuantization.validate(configuration.quantization)

    expect(configuration.quantization == nil) == true
  }

  func testConfigurationParsesValidMXFP8Quantization() throws {
    let configuration = try decodeConfiguration(
      quantization: """
        "quantization": {
          "group_size": 32,
          "bits": 8,
          "mode": "mxfp8"
        },
        """
    )

    try NVEmbeddingQuantization.validate(configuration.quantization)

    expect(configuration.quantization?.mode) == .mxfp8
    expect(configuration.quantization?.groupSize) == expectedGroupSize
    expect(configuration.quantization?.bits) == expectedBits
  }

  func testValidationRejectsMXFP8WithWrongGroupSize() throws {
    let configuration = try decodeConfiguration(
      quantization: """
        "quantization": {
          "group_size": 64,
          "bits": 8,
          "mode": "mxfp8"
        },
        """
    )

    expect { try NVEmbeddingQuantization.validate(configuration.quantization) }
      .to(throwError(NVEmbeddingQuantizationError.invalidGroupSize(wrongGroupSize)))
  }

  func testValidationRejectsMXFP8WithWrongBitCount() throws {
    let configuration = try decodeConfiguration(
      quantization: """
        "quantization": {
          "group_size": 32,
          "bits": 4,
          "mode": "mxfp8"
        },
        """
    )

    expect { try NVEmbeddingQuantization.validate(configuration.quantization) }
      .to(throwError(NVEmbeddingQuantizationError.invalidBits(wrongBits)))
  }

  func testQuantizationFilterSelectsOnlyLinearLayers() throws {
    try withMLXMetallib {
      let model = TestNVQuantizationTree()
      let selectedPaths = model.leafModules().flattened().compactMap { path, module in
        if NVEmbeddingQuantization.shouldQuantize(path: path, module: module) {
          return path
        }
        return nil
      }

      NVEmbeddingQuantization.applyForConversion(
        to: model,
        groupSize: expectedGroupSize,
        bits: expectedBits,
        mode: .mxfp8
      )

      expect(Set(selectedPaths)) == Set(["projection"])
      expect(model.projection is QuantizedLinear) == true
      expect(model.embedding is QuantizedEmbedding) == false
      expect(model.normalization is Quantized) == false
    }
  }

  private func decodeConfiguration(
    quantization: String = ""
  ) throws -> NVMistralBiDirectionalConfiguration {
    let data = Data(
      """
      {
        \(quantization)
        "hidden_size": 8,
        "num_hidden_layers": 1,
        "intermediate_size": 16,
        "num_attention_heads": 2,
        "num_key_value_heads": 1,
        "rms_norm_eps": 0.00001,
        "rope_theta": 10000,
        "vocab_size": 32
      }
      """.utf8
    )
    return try JSONDecoder().decode(NVMistralBiDirectionalConfiguration.self, from: data)
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
}

// MARK: - TestNVQuantizationTree

private final class TestNVQuantizationTree: Module {
  @ModuleInfo(key: "projection") var projection: Linear
  @ModuleInfo(key: "embedding") var embedding: Embedding
  @ModuleInfo(key: "normalization") var normalization: RMSNorm

  override init() {
    _projection.wrappedValue = Linear(testLayerWidth, testLayerWidth, bias: false)
    _embedding.wrappedValue = Embedding(
      embeddingCount: testLayerWidth,
      dimensions: testLayerWidth
    )
    _normalization.wrappedValue = RMSNorm(dimensions: testLayerWidth)
  }
}
