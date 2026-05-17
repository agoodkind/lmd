//
//  ModelCatalogKindTests.swift
//  SwiftLMRuntimeTests
//
//  Created by Alex Goodkind <alex@goodkind.io> on 2026-04-19.
//  Copyright © 2026
//

import XCTest
@testable import SwiftLMCore
@testable import SwiftLMRuntime

final class ModelCatalogKindTests: XCTestCase {
  private func tempModelDir() throws -> String {
    let base = FileManager.default.temporaryDirectory
    let dir = base.appendingPathComponent("lmd-kind-test-\(UUID().uuidString)", isDirectory: true).path
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    return dir
  }

  private func writeConfig<T: Encodable>(_ dir: String, value: T) throws {
    try writeJSON(value, to: "\(dir)/config.json")
  }

  private func writeJSON<T: Encodable>(_ value: T, to path: String) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(value)
    try data.write(to: URL(fileURLWithPath: path), options: [.atomic])
  }

  func testSentenceBertConfigImpliesEmbedding() throws {
    let dir = try tempModelDir()
    try writeJSON(EmptyJSONFixture(), to: "\(dir)/sentence_bert_config.json")
    try writeConfig(dir, value: CatalogConfigFixture(modelType: "llama"))
    let kind = ModelCatalog.inferModelKind(
      modelDir: dir, displayName: "m", slug: nil, fileManager: .default)
    XCTAssertEqual(kind, .embedding)
  }

  func testModulesJsonImpliesEmbedding() throws {
    let dir = try tempModelDir()
    try writeJSON(EmptyJSONFixture(), to: "\(dir)/modules.json")
    try writeConfig(dir, value: CatalogConfigFixture(modelType: "llama"))
    let kind = ModelCatalog.inferModelKind(
      modelDir: dir, displayName: "m", slug: nil, fileManager: .default)
    XCTAssertEqual(kind, .embedding)
  }

  func testArchitectureBertImpliesEmbedding() throws {
    let dir = try tempModelDir()
    try writeConfig(
      dir,
      value: CatalogConfigFixture(
        architectures: ["BertModel"],
        modelType: "bert"
      )
    )
    let kind = ModelCatalog.inferModelKind(
      modelDir: dir, displayName: "m", slug: nil, fileManager: .default)
    XCTAssertEqual(kind, .embedding)
  }

  func testSnowflakeArcticArchitectureImpliesEmbedding() throws {
    let dir = try tempModelDir()
    try writeConfig(
      dir,
      value: CatalogConfigFixture(architectures: ["SnowflakeArcticEmbeddingModel"])
    )
    let kind = ModelCatalog.inferModelKind(
      modelDir: dir, displayName: "m", slug: nil, fileManager: .default)
    XCTAssertEqual(kind, .embedding)
  }

  func testNVIDIAMistralBidirectionalArchitectureImpliesEmbedding() throws {
    let dir = try tempModelDir()
    try writeConfig(
      dir,
      value: CatalogConfigFixture(
        architectures: ["MistralBiDirectionalModel"],
        modelType: "mistralbidirectional"
      )
    )
    let kind = ModelCatalog.inferModelKind(
      modelDir: dir,
      displayName: "NV-EmbedCode-7b-v1",
      slug: "nvidia/NV-EmbedCode-7b-v1",
      fileManager: .default
    )
    XCTAssertEqual(kind, .embedding)
  }

  func testModelTypeBertImpliesEmbedding() throws {
    let dir = try tempModelDir()
    try writeConfig(dir, value: CatalogConfigFixture(modelType: "bert"))
    let kind = ModelCatalog.inferModelKind(
      modelDir: dir, displayName: "m", slug: nil, fileManager: .default)
    XCTAssertEqual(kind, .embedding)
  }

  func testLlamaStaysChat() throws {
    let dir = try tempModelDir()
    try writeConfig(
      dir,
      value: CatalogConfigFixture(
        architectures: ["LlamaForCausalLM"],
        modelType: "llama"
      )
    )
    let kind = ModelCatalog.inferModelKind(
      modelDir: dir, displayName: "qwen", slug: nil, fileManager: .default)
    XCTAssertEqual(kind, .chat)
  }

  func testNameHeuristicEmbed() throws {
    let dir = try tempModelDir()
    try writeConfig(dir, value: CatalogConfigFixture(modelType: "custom"))
    let kind = ModelCatalog.inferModelKind(
      modelDir: dir, displayName: "foo-embed-bar", slug: nil, fileManager: .default)
    XCTAssertEqual(kind, .embedding)
  }

  func testNameHeuristicBge() throws {
    let dir = try tempModelDir()
    try writeConfig(dir, value: CatalogConfigFixture(modelType: "custom"))
    let kind = ModelCatalog.inferModelKind(
      modelDir: dir, displayName: "model-x", slug: "org/bge-small", fileManager: .default)
    XCTAssertEqual(kind, .embedding)
  }
}

private struct EmptyJSONFixture: Encodable {}

private struct CatalogConfigFixture: Encodable {
  let architectures: [String]?
  let modelType: String?

  init(
    architectures: [String]? = nil,
    modelType: String? = nil
  ) {
    self.architectures = architectures
    self.modelType = modelType
  }

  enum CodingKeys: String, CodingKey {
    case architectures
    case modelType = "model_type"
  }
}
