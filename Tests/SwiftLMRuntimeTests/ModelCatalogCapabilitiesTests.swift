//
//  ModelCatalogCapabilitiesTests.swift
//  SwiftLMRuntimeTests
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-05-09.
//  Copyright © 2026, all rights reserved.
//

import Nimble
import XCTest

@testable import SwiftLMCore
@testable import SwiftLMRuntime

final class ModelCatalogCapabilitiesTests: XCTestCase {
  private var tempDir: URL!

  override func setUp() {
    super.setUp()
    tempDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("lmd-capabilities-test-\(UUID().uuidString)")
    // swiftlint:disable:next force_try
    try! FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
  }

  override func tearDown() {
    try? FileManager.default.removeItem(at: tempDir)
    super.tearDown()
  }

  func testQwen25VLStructuredMetadataAdvertisesVideo() throws {
    try write(
      filename: "config.json",
      json: qwen25VLConfig(videoToken: true)
    )
    try write(
      filename: "preprocessor_config.json",
      json: qwen25VLProcessorConfig()
    )

    let capabilities = ModelCatalog.inferModelCapabilities(
      modelDir: tempDir.path,
      kind: .chat,
      fileManager: .default
    )

    expect(capabilities)
      == ModelCapabilities(text: true, vision: true, video: true, videoSamplingFPS: 2.0)
  }

  func testQwen25VLWithoutVideoTokenAdvertisesVisionOnly() throws {
    try write(
      filename: "config.json",
      json: qwen25VLConfig(videoToken: false)
    )

    let capabilities = ModelCatalog.inferModelCapabilities(
      modelDir: tempDir.path,
      kind: .chat,
      fileManager: .default
    )

    expect(capabilities) == ModelCapabilities(text: true, vision: true, video: false)
  }

  func testEmbeddingKindRemainsTextOnlyEvenWithVideoMetadata() throws {
    try write(
      filename: "config.json",
      json: qwen25VLConfig(videoToken: true)
    )
    try write(
      filename: "preprocessor_config.json",
      json: qwen25VLProcessorConfig()
    )

    let capabilities = ModelCatalog.inferModelCapabilities(
      modelDir: tempDir.path,
      kind: .embedding,
      fileManager: .default
    )

    expect(capabilities) == .textOnly
  }

  func testQwen25VLDeclaresTwoFPSSamplingRate() throws {
    try write(
      filename: "config.json",
      json: qwen25VLConfig(videoToken: true)
    )
    try write(
      filename: "preprocessor_config.json",
      json: qwen25VLProcessorConfig()
    )

    let capabilities = ModelCatalog.inferModelCapabilities(
      modelDir: tempDir.path,
      kind: .chat,
      fileManager: .default
    )

    expect(capabilities.videoSamplingFPS) == 2.0
  }

  func testCatalogAttachesDetectedCapabilitiesToDescriptor() throws {
    let publisherDir = tempDir.appendingPathComponent("mlx-community")
    let modelDir = publisherDir.appendingPathComponent("Qwen2.5-VL")
    try FileManager.default.createDirectory(at: modelDir, withIntermediateDirectories: true)
    try write(
      filename: "config.json",
      directory: modelDir,
      json: qwen25VLConfig(videoToken: true)
    )
    try write(
      filename: "preprocessor_config.json",
      directory: modelDir,
      json: qwen25VLProcessorConfig()
    )

    let root = modelDir.deletingLastPathComponent().deletingLastPathComponent()
    let models = ModelCatalog(roots: [root.path]).allModels()

    expect(models.first?.capabilities)
      == ModelCapabilities(text: true, vision: true, video: true, videoSamplingFPS: 2.0)
  }

  private func write(filename: String, directory: URL? = nil, json: String) throws {
    let file = (directory ?? tempDir).appendingPathComponent(filename)
    try json.write(to: file, atomically: true, encoding: .utf8)
  }

  private func qwen25VLConfig(videoToken: Bool) -> String {
    if videoToken {
      return """
        {
          "model_type": "qwen2_5_vl",
          "vision_config": {"hidden_size": 1280},
          "image_token_id": 151655,
          "video_token_id": 151656
        }
        """
    }
    return """
      {
        "model_type": "qwen2_5_vl",
        "vision_config": {"hidden_size": 1280},
        "image_token_id": 151655
      }
      """
  }

  private func qwen25VLProcessorConfig() -> String {
    """
    {
      "processor_class": "Qwen2_5_VLProcessor",
      "image_processor_type": "Qwen2VLImageProcessor"
    }
    """
  }
}
