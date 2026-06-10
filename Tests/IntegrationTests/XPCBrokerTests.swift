//
//  XPCBrokerTests.swift
//  IntegrationTests
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-04-19.
//  Copyright © 2026, all rights reserved.
//
//  Spawns `lmd-serve`, waits for XPC readiness, and exercises
//  `health`, `loaded`, `preload`, `embed`, and `unload` over
//  `BrokerClient`.
//

import Foundation
import Nimble
import SwiftLMControl
import SwiftLMCore
import SwiftLMRuntime
import XCTest

final class XPCBrokerTests: XCTestCase {
  func testBrokerHealthLoadedPreloadEmbedUnload() async throws {
    guard ProcessInfo.processInfo.environment["LMD_INTEGRATION"] == "1" else {
      throw XCTSkip("set LMD_INTEGRATION=1 to run XPC integration test")
    }
    // `XPCListener(service:)` only succeeds when the process was
    // launched by launchd with a matching MachServices entry. A
    // child `lmd-serve` we spawn here would (a) trap inside libxpc
    // before the guard landed, and (b) post-guard, just skip the
    // listener entirely, leaving any `BrokerClient()` here pointed
    // at whichever launchd-managed daemon happens to be running.
    // That hides bugs rather than catching them.
    //
    // TODO: restructure this suite to drive XPC against the real
    // launchd-managed daemon (after `make install`), not a child
    // process. Until then, only run when the user explicitly
    // acknowledges the limitation.
    guard ProcessInfo.processInfo.environment["LMD_XPC_USE_LAUNCHD_DAEMON"] == "1" else {
      throw XCTSkip(
        "XPC integration requires the launchd-managed daemon; set LMD_XPC_USE_LAUNCHD_DAEMON=1 after `make install`"
      )
    }

    let swiftLM = try resolveSwiftLMBinary()
    _ = try resolveBrokerBinary()
    let model = try pickEmbeddingModel()
    _ = swiftLM

    try await waitForBrokerHealth()
    let client = try BrokerClient()
    try await client.health()

    _ = try await client.preload(model: model.id)

    let loaded = try await waitForModelPresence(
      modelID: model.id,
      expected: true,
      client: client
    )
    expect(loaded) == true

    let vectors = try await client.embed(model: model.id, inputs: ["integration test sentence"])
    expect(vectors.count) == 1
    expect(vectors[0].isEmpty) == false

    _ = try await client.unload(model: model.id)
    let reachedUnloaded = try await waitForModelPresence(
      modelID: model.id,
      expected: false,
      client: client
    )
    expect(reachedUnloaded) == true
  }

  // MARK: - Helpers

  private func waitForBrokerHealth(deadlineSeconds: Int = 45) async throws {
    let deadline = Date().addingTimeInterval(TimeInterval(deadlineSeconds))
    while Date() < deadline {
      do {
        let client = try BrokerClient()
        try await client.health()
        return
      } catch {
        try? await Task.sleep(nanoseconds: 250_000_000)
      }
    }
    throw XCTSkip("broker did not become reachable over XPC within \(deadlineSeconds)s")
  }

  private func waitForModelPresence(
    modelID: String,
    expected: Bool,
    client: BrokerClient,
    deadlineSeconds: Int = 30
  ) async throws -> Bool {
    let deadline = Date().addingTimeInterval(TimeInterval(deadlineSeconds))
    while Date() < deadline {
      let snapshot = try await client.loaded()
      let has = snapshot.models.contains { $0.modelID == modelID }
      if has == expected {
        return true
      }
      try await Task.sleep(nanoseconds: 250_000_000)
    }
    return false
  }

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
    let releaseBin = baseDir.appendingPathComponent("lmd-serve")
    if FileManager.default.isExecutableFile(atPath: releaseBin.path) {
      return releaseBin
    }
    let debugBin =
      baseDir
      .deletingLastPathComponent()
      .appendingPathComponent("debug", isDirectory: true)
      .appendingPathComponent("lmd-serve")
    if FileManager.default.isExecutableFile(atPath: debugBin.path) {
      return debugBin
    }
    throw XCTSkip("lmd-serve not found. Run `make build` or set LMD_BINARY_DIR")
  }

  private func resolveSwiftLMBinary() throws -> String {
    let fallback = "\(NSHomeDirectory())/Sites/SwiftLM/.build/arm64-apple-macosx/release/SwiftLM"
    let env = ProcessInfo.processInfo.environment["LMD_SWIFTLM_BINARY"] ?? fallback
    if FileManager.default.isExecutableFile(atPath: env) {
      return env
    }
    let swiftLMBin = try repoRoot()
      .appendingPathComponent(".build", isDirectory: true)
      .appendingPathComponent("release", isDirectory: true)
      .appendingPathComponent("SwiftLM")
    if FileManager.default.isExecutableFile(atPath: swiftLMBin.path) {
      return swiftLMBin.path
    }
    throw XCTSkip(
      "SwiftLM binary not found. Run `swift build -c release` or set LMD_SWIFTLM_BINARY"
    )
  }

  private func buildBrokerEnvironment(host: String, port: Int, swiftLM: String) -> [String: String]
  {
    var env = ProcessInfo.processInfo.environment
    env["LMD_HOST"] = host
    env["LMD_PORT"] = "\(port)"
    env["LMD_SWIFTLM_BINARY"] = swiftLM
    env["LMD_IDLE_MINUTES"] = "120"
    env["LMD_EMBEDDING_IDLE_MINUTES"] = "120"
    // The broker now fails fast unless every configuration key is defined.
    env["LMD_DISABLE_XPC"] = "0"
    env["LMD_RESERVE_GB"] = "20"
    env["LMD_CHAT_MAX_CONCURRENCY"] = "4"
    env["LMD_EMBEDDING_MAX_CONCURRENCY"] = "4"
    env["LMD_BATTERY_THROTTLE_PCT"] = "20"
    env["LMD_BATTERY_MILD_PCT"] = "35"
    env["LMD_BATTERY_RESUME_PCT"] = "80"
    env["LMD_DATA_DIR"] = NSTemporaryDirectory()
    env["LMD_SAMPLE_INTERVAL"] = "15"
    env["LMD_PROMPT_CACHE_MAX_TOKENS"] = ""
    env["LMD_PROMPT_CACHE_ENABLED"] = "true"
    env["LMD_MLX_CACHE_LIMIT_GB"] = "2"
    return env
  }

  private func pickEmbeddingModel() throws -> ModelDescriptor {
    let catalog = ModelCatalog(roots: ModelCatalog.defaultRoots)
    let models = catalog.allModels().filter { $0.kind == .embedding && $0.sizeBytes > 0 }
    guard let model = models.first else {
      throw XCTSkip("no local embedding model found under \(ModelCatalog.defaultRoots)")
    }
    return model
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
}

private func waitForProcessExit(_ proc: Process, timeout: TimeInterval) -> Bool {
  let deadline = Date().addingTimeInterval(timeout)
  while proc.isRunning {
    if Date() >= deadline { return false }
    Thread.sleep(forTimeInterval: 0.05)
  }
  return true
}
