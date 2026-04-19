//
//  ModelCatalogTests.swift
//  SwiftLMRuntimeTests
//
//  Created by Alex Goodkind <alex@goodkind.io> on 2026-04-18.
//  Copyright © 2026
//

import XCTest
@testable import SwiftLMRuntime
@testable import SwiftLMCore

final class ModelCatalogTests: XCTestCase {
  private var tempDir: URL!

  override func setUp() {
    super.setUp()
    tempDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("swiftlm-tests-\(UUID().uuidString)")
    try! FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
  }

  override func tearDown() {
    try? FileManager.default.removeItem(at: tempDir)
    super.tearDown()
  }

  // Build .../mlx-community/<name>/{config.json, weights}
  private func makeFakeModel(publisher: String, name: String, sizeBytes: Int) throws {
    let dir = tempDir
      .appendingPathComponent(publisher)
      .appendingPathComponent(name)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try Data("{}".utf8).write(to: dir.appendingPathComponent("config.json"))
    try Data(repeating: 0, count: sizeBytes).write(to: dir.appendingPathComponent("weights.bin"))
  }

  func testFindsModelsUnderRoot() throws {
    try makeFakeModel(publisher: "mlx-community", name: "Qwen-Tiny", sizeBytes: 1024)
    try makeFakeModel(publisher: "mlx-community", name: "Qwen-Small", sizeBytes: 2048)

    let catalog = ModelCatalog(roots: [tempDir.path])
    let models = catalog.allModels()
    XCTAssertEqual(models.count, 2)

    let names = Set(models.map { $0.displayName })
    XCTAssertEqual(names, ["Qwen-Tiny", "Qwen-Small"])

    let tiny = models.first { $0.displayName == "Qwen-Tiny" }
    XCTAssertEqual(tiny?.slug, "mlx-community/Qwen-Tiny")
    XCTAssertGreaterThanOrEqual(tiny?.sizeBytes ?? 0, 1024)
  }

  func testIgnoresNonModelDirectories() throws {
    let bogus = tempDir.appendingPathComponent("bogus")
    try FileManager.default.createDirectory(at: bogus, withIntermediateDirectories: true)
    try Data("hi".utf8).write(to: bogus.appendingPathComponent("readme.txt"))

    let catalog = ModelCatalog(roots: [tempDir.path])
    XCTAssertTrue(catalog.allModels().isEmpty)
  }

  func testMissingRootIsIgnored() {
    let catalog = ModelCatalog(roots: ["/definitely/not/there"])
    XCTAssertTrue(catalog.allModels().isEmpty)
  }

  func testSortedByDisplayName() throws {
    try makeFakeModel(publisher: "mlx-community", name: "Zeta", sizeBytes: 1)
    try makeFakeModel(publisher: "mlx-community", name: "Alpha", sizeBytes: 1)
    let models = ModelCatalog(roots: [tempDir.path]).allModels()
    XCTAssertEqual(models.map { $0.displayName }, ["Alpha", "Zeta"])
  }

  // Regression: when the same model lives in both the LM Studio
  // layout and the HF hub cache, allModels dedups by slug and keeps
  // the larger one (full weights beat an empty HF snapshot stub).
  func testDedupsSameSlugKeepingLargestSize() throws {
    // LM Studio layout.
    try makeFakeModel(publisher: "mlx-community", name: "Qwen-Dup", sizeBytes: 4096)

    // HF cache layout with the same slug. Smaller on disk (symlink-only
    // snapshot stub).
    let hub = tempDir.appendingPathComponent("hub")
    let snap = hub
      .appendingPathComponent("models--mlx-community--Qwen-Dup")
      .appendingPathComponent("snapshots")
      .appendingPathComponent("deadbeef")
    try FileManager.default.createDirectory(at: snap, withIntermediateDirectories: true)
    try Data("{}".utf8).write(to: snap.appendingPathComponent("config.json"))
    try Data(repeating: 0, count: 16).write(to: snap.appendingPathComponent("weights.bin"))

    let catalog = ModelCatalog(roots: [tempDir.path])
    let models = catalog.allModels()
    XCTAssertEqual(models.count, 1, "should dedup duplicate slug across roots")
    XCTAssertGreaterThanOrEqual(models.first?.sizeBytes ?? 0, 4096, "kept the larger entry")
  }

  // Regression: the HF cache stores models at
  // hub/models--<publisher>--<repo>/snapshots/<sha>/config.json and
  // used to surface the raw sha as displayName (e.g.
  // "06cacdcc84198b112b7c83224f816c6c7aa4a4a9"). The catalog now
  // translates the grandparent dir name into a publisher/repo slug
  // and uses the repo name as displayName.
  func testHFCacheSnapshotProducesRepoName() throws {
    let hub = tempDir.appendingPathComponent("hub")
    let snap = hub
      .appendingPathComponent("models--mlx-community--Qwen3.5-4B-MLX-4bit")
      .appendingPathComponent("snapshots")
      .appendingPathComponent("06cacdcc84198b112b7c83224f816c6c7aa4a4a9")
    try FileManager.default.createDirectory(at: snap, withIntermediateDirectories: true)
    try Data("{}".utf8).write(to: snap.appendingPathComponent("config.json"))
    try Data(repeating: 0, count: 512).write(to: snap.appendingPathComponent("weights.bin"))

    let catalog = ModelCatalog(roots: [hub.path])
    let models = catalog.allModels()
    XCTAssertEqual(models.count, 1)
    XCTAssertEqual(models.first?.displayName, "Qwen3.5-4B-MLX-4bit")
    XCTAssertEqual(models.first?.slug, "mlx-community/Qwen3.5-4B-MLX-4bit")
  }
}
