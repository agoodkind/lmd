//
//  BenchOrchestratorTests.swift
//  SwiftLMRuntimeTests
//
//  Created by Alex Goodkind <alex@goodkind.io> on 2026-04-18.
//  Copyright © 2026
//

import XCTest
@testable import SwiftLMRuntime

private final class FakeBackend: BenchBackend, @unchecked Sendable {
  struct Call: Equatable {
    let model: String
    let variant: String
    let prompt: String
  }
  var loaded: [String] = []
  var calls: [Call] = []
  var failModelID: String?
  var failCellPattern: String?
  private let syncQ = DispatchQueue(label: "bench-fake-backend")

  func loadIfNeeded(_ model: BenchModelSpec) throws {
    try syncQ.sync {
      if let f = failModelID, f == model.id {
        throw NSError(domain: "fake", code: 1)
      }
      loaded.append(model.id)
    }
  }

  func runChat(
    model: BenchModelSpec,
    variant: BenchVariant,
    systemPrompt: String,
    userContent: String,
    timeout: TimeInterval
  ) async throws -> Data {
    let shouldFail = syncQ.sync { () -> Bool in
      calls.append(Call(
        model: model.id,
        variant: variant.name,
        prompt: String(systemPrompt.prefix(16))
      ))
      if let pattern = failCellPattern {
        return systemPrompt.contains(pattern)
      }
      return false
    }
    if shouldFail {
      throw NSError(domain: "fake", code: 2)
    }
    return #"{"ok": true}"#.data(using: .utf8)!
  }

  func unload(_ model: BenchModelSpec) {}
}

final class BenchOrchestratorTests: XCTestCase {
  private var tempDir: URL!

  override func setUp() {
    super.setUp()
    tempDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("bench-orch-\(UUID().uuidString)")
    try! FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
  }

  override func tearDown() {
    try? FileManager.default.removeItem(at: tempDir)
    super.tearDown()
  }

  private func makeConfig(
    prompts: [(name: String, body: String)],
    models: [BenchModelSpec],
    variants: [BenchVariant]
  ) throws -> BenchConfig {
    let pd = tempDir.appendingPathComponent("prompts")
    let rd = tempDir.appendingPathComponent("results")
    try FileManager.default.createDirectory(at: pd, withIntermediateDirectories: true)
    for p in prompts {
      try p.body.data(using: .utf8)!.write(to: pd.appendingPathComponent(p.name))
    }
    return BenchConfig(
      promptsDir: pd.path,
      resultsDir: rd.path,
      models: models,
      variants: variants
    )
  }

  func testRunsEveryCellInMatrix() async throws {
    let cfg = try makeConfig(
      prompts: [
        (name: "review-a.txt", body: "ask a"),
        (name: "review-b.txt", body: "ask b"),
        (name: "chat-x.txt", body: "ask x"),
      ],
      models: [
        BenchModelSpec(id: "m1"),
        BenchModelSpec(id: "m2"),
      ],
      variants: [
        BenchVariant(name: "review", promptGlob: "review-*.txt"),
        BenchVariant(name: "chat", promptGlob: "chat-*.txt"),
      ]
    )
    let backend = FakeBackend()
    let orch = BenchOrchestrator(config: cfg, backend: backend)
    let (done, failed) = await orch.run()
    XCTAssertEqual(done, 6)
    XCTAssertEqual(failed, 0)
    XCTAssertEqual(backend.loaded, ["m1", "m2"])
    XCTAssertEqual(backend.calls.count, 6)
  }

  func testSkipsExistingResults() async throws {
    let cfg = try makeConfig(
      prompts: [
        (name: "review-a.txt", body: "x"),
      ],
      models: [BenchModelSpec(id: "m1")],
      variants: [BenchVariant(name: "review", promptGlob: "review-*.txt")]
    )
    // Pre-populate result
    let path = BenchCell(
      model: BenchModelSpec(id: "m1"),
      variant: BenchVariant(name: "review", promptGlob: "*"),
      promptFilename: "review-a.txt"
    ).resultPath(under: cfg.resultsDir)
    try FileManager.default.createDirectory(
      atPath: (path as NSString).deletingLastPathComponent,
      withIntermediateDirectories: true
    )
    try Data("stale".utf8).write(to: URL(fileURLWithPath: path))

    let backend = FakeBackend()
    let orch = BenchOrchestrator(config: cfg, backend: backend)
    let (done, failed) = await orch.run()
    XCTAssertEqual(done, 0)
    XCTAssertEqual(failed, 0)
    XCTAssertTrue(backend.calls.isEmpty)
  }

  func testLoadFailureSkipsCellsForThatModelOnly() async throws {
    let cfg = try makeConfig(
      prompts: [(name: "r-a.txt", body: "x")],
      models: [
        BenchModelSpec(id: "broken"),
        BenchModelSpec(id: "ok"),
      ],
      variants: [BenchVariant(name: "r", promptGlob: "r-*.txt")]
    )
    let backend = FakeBackend()
    backend.failModelID = "broken"
    let orch = BenchOrchestrator(config: cfg, backend: backend)
    let (done, failed) = await orch.run()
    XCTAssertEqual(done, 1)
    XCTAssertEqual(failed, 1)
  }
}
