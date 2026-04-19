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

  private func writeConfig(_ dir: String, json: String) throws {
    let path = "\(dir)/config.json"
    try json.write(toFile: path, atomically: true, encoding: .utf8)
  }

  func testSentenceBertConfigImpliesEmbedding() throws {
    let dir = try tempModelDir()
    try "{}".write(toFile: "\(dir)/sentence_bert_config.json", atomically: true, encoding: .utf8)
    try writeConfig(dir, json: #"{"model_type": "llama"}"#)
    let kind = ModelCatalog.inferModelKind(
      modelDir: dir, displayName: "m", slug: nil, fileManager: .default)
    XCTAssertEqual(kind, .embedding)
  }

  func testModulesJsonImpliesEmbedding() throws {
    let dir = try tempModelDir()
    try "{}".write(toFile: "\(dir)/modules.json", atomically: true, encoding: .utf8)
    try writeConfig(dir, json: #"{"model_type": "llama"}"#)
    let kind = ModelCatalog.inferModelKind(
      modelDir: dir, displayName: "m", slug: nil, fileManager: .default)
    XCTAssertEqual(kind, .embedding)
  }

  func testArchitectureBertImpliesEmbedding() throws {
    let dir = try tempModelDir()
    try writeConfig(
      dir,
      json: #"{"architectures": ["BertModel"], "model_type": "bert"}"#
    )
    let kind = ModelCatalog.inferModelKind(
      modelDir: dir, displayName: "m", slug: nil, fileManager: .default)
    XCTAssertEqual(kind, .embedding)
  }

  func testSnowflakeArcticArchitectureImpliesEmbedding() throws {
    let dir = try tempModelDir()
    try writeConfig(
      dir,
      json: #"{"architectures": ["SnowflakeArcticEmbeddingModel"]}"#
    )
    let kind = ModelCatalog.inferModelKind(
      modelDir: dir, displayName: "m", slug: nil, fileManager: .default)
    XCTAssertEqual(kind, .embedding)
  }

  func testModelTypeBertImpliesEmbedding() throws {
    let dir = try tempModelDir()
    try writeConfig(dir, json: #"{"model_type": "bert"}"#)
    let kind = ModelCatalog.inferModelKind(
      modelDir: dir, displayName: "m", slug: nil, fileManager: .default)
    XCTAssertEqual(kind, .embedding)
  }

  func testLlamaStaysChat() throws {
    let dir = try tempModelDir()
    try writeConfig(dir, json: #"{"model_type": "llama", "architectures": ["LlamaForCausalLM"]}"#)
    let kind = ModelCatalog.inferModelKind(
      modelDir: dir, displayName: "qwen", slug: nil, fileManager: .default)
    XCTAssertEqual(kind, .chat)
  }

  func testNameHeuristicEmbed() throws {
    let dir = try tempModelDir()
    try writeConfig(dir, json: #"{"model_type": "custom"}"#)
    let kind = ModelCatalog.inferModelKind(
      modelDir: dir, displayName: "foo-embed-bar", slug: nil, fileManager: .default)
    XCTAssertEqual(kind, .embedding)
  }

  func testNameHeuristicBge() throws {
    let dir = try tempModelDir()
    try writeConfig(dir, json: #"{"model_type": "custom"}"#)
    let kind = ModelCatalog.inferModelKind(
      modelDir: dir, displayName: "model-x", slug: "org/bge-small", fileManager: .default)
    XCTAssertEqual(kind, .embedding)
  }
}
