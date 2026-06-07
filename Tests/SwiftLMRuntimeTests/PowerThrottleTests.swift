//
//  PowerThrottleTests.swift
//  SwiftLMRuntimeTests
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-06-04.
//  Copyright © 2026, all rights reserved.
//

import XCTest

@testable import SwiftLMBackend
@testable import SwiftLMCore
@testable import SwiftLMRuntime

private final class RecordingEmbeddingBackend: EmbeddingBackendProtocol, @unchecked Sendable {
  let modelID: String
  let sizeBytes: Int64
  private let lock = NSLock()
  private var lastLevel: PowerThrottleLevel = .none

  var appliedLevel: PowerThrottleLevel {
    lock.lock()
    defer { lock.unlock() }
    return lastLevel
  }

  init(modelID: String, sizeBytes: Int64) {
    self.modelID = modelID
    self.sizeBytes = sizeBytes
  }

  func launch() async throws {}
  func shutdown() {}
  func embed(inputs: [String]) async throws -> [[Float]] { inputs.map { _ in [Float(0)] } }
  func applyPowerThrottle(_ level: PowerThrottleLevel) {
    lock.lock()
    lastLevel = level
    lock.unlock()
  }
}

final class RouterPowerThrottleTests: XCTestCase {
  private func makeRouter(embeddingMaxConcurrency: Int?) -> ModelRouter {
    ModelRouter(
      reserveBytes: 0,
      memoryProbe: { MemoryReading(availableBytes: .max, underPressure: false) },
      spawner: { _, _, _ in fatalError("spawner unused in throttle tests") },
      embeddingMaxConcurrency: embeddingMaxConcurrency
    )
  }

  func testMildCapsConcurrencyAndPaces() async {
    let router = makeRouter(embeddingMaxConcurrency: 4)
    await router.applyPowerThrottle(.mild)
    let concurrency = await router.embeddingMaxConcurrency
    let pacing = await router.embeddingPacing()
    XCTAssertEqual(concurrency, 2)
    XCTAssertEqual(pacing, 75_000_000)
  }

  func testHardCapsConcurrencyAndPaces() async {
    let router = makeRouter(embeddingMaxConcurrency: 4)
    await router.applyPowerThrottle(.hard)
    let concurrency = await router.embeddingMaxConcurrency
    let pacing = await router.embeddingPacing()
    XCTAssertEqual(concurrency, 1)
    XCTAssertEqual(pacing, 250_000_000)
  }

  func testNoneRestoresConfigured() async {
    let router = makeRouter(embeddingMaxConcurrency: 4)
    await router.applyPowerThrottle(.hard)
    await router.applyPowerThrottle(.none)
    let concurrency = await router.embeddingMaxConcurrency
    let pacing = await router.embeddingPacing()
    XCTAssertEqual(concurrency, 4)
    XCTAssertEqual(pacing, 0)
  }

  func testNeverRaisesAboveConfiguredCeiling() async {
    let router = makeRouter(embeddingMaxConcurrency: 1)
    await router.applyPowerThrottle(.mild)
    let concurrency = await router.embeddingMaxConcurrency
    XCTAssertEqual(concurrency, 1)
  }

  func testUnboundedConfiguredUsesLevelCapThenRestoresToNil() async {
    let router = makeRouter(embeddingMaxConcurrency: nil)
    await router.applyPowerThrottle(.mild)
    let mild = await router.embeddingMaxConcurrency
    XCTAssertEqual(mild, 2)
    await router.applyPowerThrottle(.none)
    let restored = await router.embeddingMaxConcurrency
    XCTAssertNil(restored)
  }

  func testBackendSpawnedWhileThrottledInheritsLevel() async throws {
    // Use mild: it forwards the level to a spawned backend without halting
    // admission. (hard halts, so a model cannot be routed while it is active.)
    let backend = RecordingEmbeddingBackend(modelID: "/tmp/embed", sizeBytes: 0)
    let router = ModelRouter(
      reserveBytes: 0,
      memoryProbe: { MemoryReading(availableBytes: .max, underPressure: false) },
      spawner: { _, _, _ in fatalError("spawner unused in throttle tests") },
      embeddingSpawner: { _, _ in backend }
    )
    await router.applyPowerThrottle(.mild)
    let model = ModelDescriptor(
      id: "/tmp/embed", displayName: "embed", path: "/tmp/embed", sizeBytes: 0, kind: .embedding)
    _ = try await router.routeEmbeddingAndBegin(model)
    XCTAssertEqual(backend.appliedLevel, .mild)
  }

  // MARK: - Halt (refuse new, drain in-flight)

  func testHardHaltsAdmissionMildAndNoneDoNot() async {
    let router = makeRouter(embeddingMaxConcurrency: 4)
    let initial = await router.isPowerHalted()
    XCTAssertFalse(initial)
    await router.applyPowerThrottle(.mild)
    let mild = await router.isPowerHalted()
    XCTAssertFalse(mild)
    await router.applyPowerThrottle(.hard)
    let hard = await router.isPowerHalted()
    XCTAssertTrue(hard)
    await router.applyPowerThrottle(.none)
    let cleared = await router.isPowerHalted()
    XCTAssertFalse(cleared)
  }

  func testHardRefusesNewChatBeforeSpawning() async {
    let router = makeRouter(embeddingMaxConcurrency: 4)
    await router.applyPowerThrottle(.hard)
    let model = ModelDescriptor(
      id: "/tmp/chat", displayName: "chat", path: "/tmp/chat", sizeBytes: 0, kind: .chat)
    do {
      _ = try await router.routeAndBegin(model)
      XCTFail("expected powerPaused")
    } catch let error as ModelRouter.RouteError {
      guard case .powerPaused = error else {
        XCTFail("expected powerPaused, got \(error)")
        return
      }
    } catch {
      XCTFail("unexpected error \(error)")
    }
  }

  func testHardRefusesNewEmbeddingBeforeSpawning() async {
    let router = ModelRouter(
      reserveBytes: 0,
      memoryProbe: { MemoryReading(availableBytes: .max, underPressure: false) },
      spawner: { _, _, _ in fatalError("spawner unused in throttle tests") },
      embeddingSpawner: { _, _ in fatalError("embeddingSpawner must not run while halted") }
    )
    await router.applyPowerThrottle(.hard)
    let model = ModelDescriptor(
      id: "/tmp/embed", displayName: "embed", path: "/tmp/embed", sizeBytes: 0, kind: .embedding)
    do {
      _ = try await router.routeEmbeddingAndBegin(model)
      XCTFail("expected powerPaused")
    } catch let error as ModelRouter.RouteError {
      guard case .powerPaused = error else {
        XCTFail("expected powerPaused, got \(error)")
        return
      }
    } catch {
      XCTFail("unexpected error \(error)")
    }
  }
}
