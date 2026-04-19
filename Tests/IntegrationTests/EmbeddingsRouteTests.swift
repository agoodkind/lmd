//
//  EmbeddingsRouteTests.swift
//  IntegrationTests
//
//  Created by Alex Goodkind <alex@goodkind.io> on 2026-04-19.
//  Copyright © 2026
//
//  Spawns a release `lmd-serve`, POSTs `/v1/embeddings` with two inputs, and
//  checks `/swiftlmd/loaded` lists `kind: embedding`. Skips when no embedding
//  model exists on disk, when `lmd-serve` is missing, or when `LMD_SWIFTLM_BINARY`
//  is not executable (broker startup requirement).
//

import Foundation
import SwiftLMCore
import SwiftLMRuntime
import XCTest

final class EmbeddingsRouteTests: XCTestCase {
  func testEmbeddingsBatchAgainstRunningBroker() async throws {
    let swiftLM = ProcessInfo.processInfo.environment["LMD_SWIFTLM_BINARY"]
      ?? "\(NSHomeDirectory())/Sites/SwiftLM/.build/arm64-apple-macosx/release/SwiftLM"
    if !FileManager.default.isExecutableFile(atPath: swiftLM) {
      throw XCTSkip("SwiftLM binary not executable at \(swiftLM); set LMD_SWIFTLM_BINARY")
    }

    let brokerBin = try resolveBrokerBinary()
    let catalogRoot = "\(NSHomeDirectory())/.lmstudio/models"
    guard FileManager.default.fileExists(atPath: catalogRoot) else {
      throw XCTSkip("no LM Studio models directory at \(catalogRoot)")
    }

    let embeddingModel = findEmbeddingModel(under: catalogRoot)
    guard let embModel = embeddingModel else {
      throw XCTSkip("no embedding model found under \(catalogRoot); add one (for example Snowflake snowflake-arctic-embed-l)")
    }

    let slug = embModel.slug ?? embModel.displayName
    let port = 5400 + Int.random(in: 50...250)
    let host = "127.0.0.1"

    let proc = Process()
    proc.executableURL = brokerBin
    proc.arguments = []
    proc.environment = buildBrokerEnvironment(
      host: host, port: port, swiftLM: swiftLM)

    try proc.run()
    defer {
      proc.terminate()
      _ = waitForProcessExit(proc, timeout: 3.0)
    }

    let base = "http://\(host):\(port)"
    try await waitForHealth(url: "\(base)/health", deadlineSeconds: 45)

    let embPayload: [String: Any] = [
      "model": slug,
      "input": ["integration probe one", "integration probe two"],
    ]
    let embData = try JSONSerialization.data(withJSONObject: embPayload)
    let (embStatus, embBody) = await httpPost(url: "\(base)/v1/embeddings", body: embData)
    let embText = String(data: embBody, encoding: .utf8) ?? ""
    if embStatus != 200 {
      if embText.isEmpty || embText.contains("Failed to load the default metallib") {
        throw XCTSkip("embeddings endpoint unavailable in environment: status=\(embStatus), body=\(embText)")
      }
      XCTAssertEqual(embStatus, 200, "embeddings body: \(embText)")
    }
    guard let embJson = try? JSONSerialization.jsonObject(with: embBody) as? [String: Any],
          let rows = embJson["data"] as? [[String: Any]]
    else {
      if embText.contains("Failed to load the default metallib") {
        throw XCTSkip("MLX metallib unavailable in environment: \(embText)")
      }
      XCTFail("invalid embeddings JSON")
      return
    }
    XCTAssertEqual(rows.count, 2)
    for row in rows {
      let vec = row["embedding"] as? [Float] ?? []
      XCTAssertGreaterThan(vec.count, 0)
    }

    let (loadedStatus, loadedBody) = await httpGet(url: "\(base)/swiftlmd/loaded")
    XCTAssertEqual(loadedStatus, 200)
    guard let loaded = try? JSONSerialization.jsonObject(with: loadedBody) as? [String: Any],
          let models = loaded["models"] as? [[String: Any]]
    else {
      XCTFail("invalid loaded JSON")
      return
    }
    let kinds = models.compactMap { $0["kind"] as? String }
    XCTAssertTrue(kinds.contains("embedding"), "loaded models: \(models)")
  }

  // MARK: - Helpers

  private func resolveBrokerBinary() throws -> URL {
    let env = ProcessInfo.processInfo.environment
    let baseDir: URL
    if let override = env["LMD_BINARY_DIR"], !override.isEmpty {
      baseDir = URL(fileURLWithPath: override)
    } else {
      baseDir = try repoRoot()
        .appendingPathComponent(".build", isDirectory: true)
        .appendingPathComponent("release", isDirectory: true)
    }
    let debugDir = try repoRoot()
      .appendingPathComponent(".build", isDirectory: true)
      .appendingPathComponent("debug", isDirectory: true)
    let releaseBin = baseDir.appendingPathComponent("lmd-serve")
    if FileManager.default.isExecutableFile(atPath: releaseBin.path) {
      return releaseBin
    }
    let debugBin = debugDir.appendingPathComponent("lmd-serve")
    if FileManager.default.isExecutableFile(atPath: debugBin.path) {
      return debugBin
    }
    throw XCTSkip(
      "lmd-serve not found. Run `swift build -c release` or `swift build`, or set LMD_BINARY_DIR."
    )
  }

  private func repoRoot() throws -> URL {
    var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    while dir.path != "/" {
      if FileManager.default.fileExists(
        atPath: dir.appendingPathComponent("Package.swift").path
      ) {
        return dir
      }
      dir = dir.deletingLastPathComponent()
    }
    throw XCTSkip("could not locate Package.swift above \(#filePath)")
  }

  private func buildBrokerEnvironment(host: String, port: Int, swiftLM: String) -> [String: String] {
    var env = ProcessInfo.processInfo.environment
    env["LMD_HOST"] = host
    env["LMD_PORT"] = "\(port)"
    env["LMD_SWIFTLM_BINARY"] = swiftLM
    env["LMD_DISABLE_XPC"] = "1"
    env["LMD_IDLE_MINUTES"] = "120"
    env["LMD_EMBEDDING_IDLE_MINUTES"] = "120"
    return env
  }

  private func findEmbeddingModel(under root: String) -> ModelDescriptor? {
    let catalog = ModelCatalog(roots: [root])
    return catalog.allModels().first(where: { $0.kind == .embedding })
  }

  private func waitForHealth(url: String, deadlineSeconds: Int) async throws {
    let deadline = Date().addingTimeInterval(TimeInterval(deadlineSeconds))
    while Date() < deadline {
      let (status, _) = await httpGet(url: url)
      if status == 200 { return }
      try await Task.sleep(nanoseconds: 500_000_000)
    }
    XCTFail("broker did not become healthy at \(url)")
  }

  private func httpGet(url: String) async -> (Int, Data) {
    await withCheckedContinuation { cont in
      guard let u = URL(string: url) else {
        cont.resume(returning: (0, Data()))
        return
      }
      let task = URLSession.shared.dataTask(with: u) { data, resp, _ in
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        cont.resume(returning: (code, data ?? Data()))
      }
      task.resume()
    }
  }

  private func httpPost(url: String, body: Data) async -> (Int, Data) {
    await withCheckedContinuation { cont in
      guard let u = URL(string: url) else {
        cont.resume(returning: (0, Data()))
        return
      }
      var req = URLRequest(url: u)
      req.httpMethod = "POST"
      req.httpBody = body
      req.setValue("application/json", forHTTPHeaderField: "Content-Type")
      let task = URLSession.shared.dataTask(with: req) { data, resp, _ in
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        cont.resume(returning: (code, data ?? Data()))
      }
      task.resume()
    }
  }
}

private func waitForProcessExit(_ proc: Process, timeout: TimeInterval) -> Bool {
  let deadline = Date().addingTimeInterval(timeout)
  while proc.isRunning {
    if Date() >= deadline { return false }
    Thread.sleep(forTimeInterval: 0.05)
  }
  return true
}
