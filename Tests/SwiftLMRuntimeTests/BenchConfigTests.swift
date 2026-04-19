//
//  BenchConfigTests.swift
//  SwiftLMRuntimeTests
//
//  Created by Alex Goodkind <alex@goodkind.io> on 2026-04-18.
//  Copyright © 2026
//

import XCTest
@testable import SwiftLMRuntime

final class BenchConfigTests: XCTestCase {
  private var tempDir: URL!

  override func setUp() {
    super.setUp()
    tempDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("bench-cfg-\(UUID().uuidString)")
    try! FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
  }

  override func tearDown() {
    try? FileManager.default.removeItem(at: tempDir)
    super.tearDown()
  }

  private func touch(_ name: String) throws {
    try Data().write(to: tempDir.appendingPathComponent(name))
  }

  // MARK: - Matrix expansion

  func testExpandsCartesianProductOfModelsAndVariants() throws {
    try touch("review-security.txt")
    try touch("review-general.txt")
    try touch("chat-explain.txt")

    let cfg = BenchConfig(
      promptsDir: tempDir.path,
      resultsDir: "/tmp/out",
      models: [
        BenchModelSpec(id: "a"),
        BenchModelSpec(id: "b"),
      ],
      variants: [
        BenchVariant(name: "review", promptGlob: "review-*.txt"),
        BenchVariant(name: "chat", promptGlob: "chat-*.txt"),
      ]
    )
    let matrix = cfg.expandMatrix()
    // 2 models x (2 review + 1 chat) = 6 cells
    XCTAssertEqual(matrix.count, 6)
  }

  func testGlobExcludesUnmatchedFiles() throws {
    try touch("review-security.txt")
    try touch("readme.md")
    try touch("chat-explain.txt")

    let cfg = BenchConfig(
      promptsDir: tempDir.path,
      resultsDir: "/tmp/out",
      models: [BenchModelSpec(id: "a")],
      variants: [BenchVariant(name: "review", promptGlob: "review-*.txt")]
    )
    let matrix = cfg.expandMatrix()
    XCTAssertEqual(matrix.count, 1)
    XCTAssertEqual(matrix.first?.promptFilename, "review-security.txt")
  }

  func testEmptyPromptsDirYieldsEmptyMatrix() {
    let cfg = BenchConfig(
      promptsDir: tempDir.path,
      resultsDir: "/tmp/out",
      models: [BenchModelSpec(id: "a")],
      variants: [BenchVariant(name: "review", promptGlob: "*.txt")]
    )
    XCTAssertTrue(cfg.expandMatrix().isEmpty)
  }

  // MARK: - Cell paths

  func testResultPathSanitizesSlashes() {
    let cell = BenchCell(
      model: BenchModelSpec(id: "mlx-community/Qwen3-Coder-30B"),
      variant: BenchVariant(name: "review", promptGlob: "review-*.txt"),
      promptFilename: "review-security.txt"
    )
    let path = cell.resultPath(under: "/tmp/out")
    XCTAssertEqual(
      path,
      "/tmp/out/mlx-community_Qwen3-Coder-30B/review-security.json"
    )
  }

  func testResultPathStripsTxtExtension() {
    let cell = BenchCell(
      model: BenchModelSpec(id: "m"),
      variant: BenchVariant(name: "v", promptGlob: "*"),
      promptFilename: "hello.world.txt"
    )
    // Only the final .txt should be stripped.
    XCTAssertEqual(
      cell.resultPath(under: "/r"),
      "/r/m/hello.world.json"
    )
  }
}
