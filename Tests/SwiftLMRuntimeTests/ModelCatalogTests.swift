//
//  ModelCatalogTests.swift
//  SwiftLMRuntimeTests
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-04-18.
//  Copyright © 2026, all rights reserved.
//

import Nimble
import XCTest

@testable import SwiftLMCore
@testable import SwiftLMRuntime

final class ModelCatalogTests: XCTestCase {
  private var tempDir: URL!

  override func setUp() {
    super.setUp()
    tempDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("swiftlm-tests-\(UUID().uuidString)")
    // swiftlint:disable:next force_try
    try! FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
  }

  override func tearDown() {
    try? FileManager.default.removeItem(at: tempDir)
    super.tearDown()
  }

  // Build .../mlx-community/<name>/{config.json, weights}
  private func makeFakeModel(publisher: String, name: String, sizeBytes: Int) throws {
    let dir =
      tempDir
      .appendingPathComponent(publisher)
      .appendingPathComponent(name)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try Data("{}".utf8).write(to: dir.appendingPathComponent("config.json"))
    try Data(repeating: 0, count: sizeBytes).write(to: dir.appendingPathComponent("weights.bin"))
  }

  func testFindsModelsUnderRoot() throws {
    try makeFakeModel(publisher: "mlx-community", name: "Qwen-Tiny", sizeBytes: 1_024)
    try makeFakeModel(publisher: "mlx-community", name: "Qwen-Small", sizeBytes: 2_048)

    let catalog = ModelCatalog(roots: [tempDir.path])
    let models = catalog.allModels()
    expect(models.count) == 2

    let names = Set(models.map(\.displayName))
    expect(names) == ["Qwen-Tiny", "Qwen-Small"]

    let tiny = models.first { $0.displayName == "Qwen-Tiny" }
    expect(tiny?.slug) == "mlx-community/Qwen-Tiny"
    expect(tiny?.sizeBytes ?? 0) >= 1_024
  }

  func testIgnoresNonModelDirectories() throws {
    let bogus = tempDir.appendingPathComponent("bogus")
    try FileManager.default.createDirectory(at: bogus, withIntermediateDirectories: true)
    try Data("hi".utf8).write(to: bogus.appendingPathComponent("readme.txt"))

    let catalog = ModelCatalog(roots: [tempDir.path])
    expect(catalog.allModels().isEmpty) == true
  }

  func testMissingRootIsIgnored() {
    let catalog = ModelCatalog(roots: ["/definitely/not/there"])
    expect(catalog.allModels().isEmpty) == true
  }

  // A directory with config.json but no weight files is a metadata-only or
  // partial download (an interrupted `lmd pull` that fetched config + tokenizer
  // but no weights). The catalog must not advertise it, because loading it
  // fails or, worse, misbehaves silently.
  func testConfigWithoutWeightsIsNotListed() throws {
    let dir =
      tempDir
      .appendingPathComponent("LiquidAI")
      .appendingPathComponent("LFM2.5-1.2B-Instruct")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try Data("{}".utf8).write(to: dir.appendingPathComponent("config.json"))
    try Data("{}".utf8).write(to: dir.appendingPathComponent("tokenizer.json"))
    try Data("template".utf8).write(to: dir.appendingPathComponent("chat_template.jinja"))

    let catalog = ModelCatalog(roots: [tempDir.path])
    expect(catalog.allModels().isEmpty) == true
  }

  // A complete model alongside a weight-less sibling still surfaces, and only
  // the complete one is listed.
  func testWeightlessSiblingDoesNotHideCompleteModel() throws {
    try makeFakeModel(publisher: "mlx-community", name: "Real-4bit", sizeBytes: 2_048)

    let stub =
      tempDir
      .appendingPathComponent("LiquidAI")
      .appendingPathComponent("LFM2.5-1.2B-Instruct")
    try FileManager.default.createDirectory(at: stub, withIntermediateDirectories: true)
    try Data("{}".utf8).write(to: stub.appendingPathComponent("config.json"))

    let models = ModelCatalog(roots: [tempDir.path]).allModels()
    expect(models.map(\.displayName)) == ["Real-4bit"]
  }

  func testSortedByDisplayName() throws {
    try makeFakeModel(publisher: "mlx-community", name: "Zeta", sizeBytes: 1)
    try makeFakeModel(publisher: "mlx-community", name: "Alpha", sizeBytes: 1)
    let models = ModelCatalog(roots: [tempDir.path]).allModels()
    expect(models.map(\.displayName)) == ["Alpha", "Zeta"]
  }

  // Regression: when the same model lives in both the LM Studio
  // layout and the HF hub cache, allModels dedups by slug and keeps
  // the larger one (full weights beat an empty HF snapshot stub).
  func testDedupsSameSlugKeepingLargestSize() throws {
    // LM Studio layout.
    try makeFakeModel(publisher: "mlx-community", name: "Qwen-Dup", sizeBytes: 4_096)

    // HF cache layout with the same slug. Smaller on disk (symlink-only
    // snapshot stub).
    let hub = tempDir.appendingPathComponent("hub")
    let snap =
      hub
      .appendingPathComponent("models--mlx-community--Qwen-Dup")
      .appendingPathComponent("snapshots")
      .appendingPathComponent("deadbeef")
    try FileManager.default.createDirectory(at: snap, withIntermediateDirectories: true)
    try Data("{}".utf8).write(to: snap.appendingPathComponent("config.json"))
    try Data(repeating: 0, count: 16).write(to: snap.appendingPathComponent("weights.bin"))

    let catalog = ModelCatalog(roots: [tempDir.path])
    let models = catalog.allModels()
    expect(models.count) == 1
    expect(models.first?.sizeBytes ?? 0) >= 4_096
  }

  // Regression: the HF cache stores models at
  // hub/models--<publisher>--<repo>/snapshots/<sha>/config.json and
  // used to surface the raw sha as displayName (e.g.
  // "06cacdcc84198b112b7c83224f816c6c7aa4a4a9"). The catalog now
  // translates the grandparent dir name into a publisher/repo slug
  // and uses the repo name as displayName.
  func testHFCacheSnapshotProducesRepoName() throws {
    let hub = tempDir.appendingPathComponent("hub")
    let snap =
      hub
      .appendingPathComponent("models--mlx-community--Qwen3.5-4B-MLX-4bit")
      .appendingPathComponent("snapshots")
      .appendingPathComponent("06cacdcc84198b112b7c83224f816c6c7aa4a4a9")
    try FileManager.default.createDirectory(at: snap, withIntermediateDirectories: true)
    try Data("{}".utf8).write(to: snap.appendingPathComponent("config.json"))
    try Data(repeating: 0, count: 512).write(to: snap.appendingPathComponent("weights.bin"))

    let catalog = ModelCatalog(roots: [hub.path])
    let models = catalog.allModels()
    expect(models.count) == 1
    expect(models.first?.displayName) == "Qwen3.5-4B-MLX-4bit"
    expect(models.first?.slug) == "mlx-community/Qwen3.5-4B-MLX-4bit"
  }
}
