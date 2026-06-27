//
//  PowerThrottleTests.swift
//  SwiftLMRuntimeTests
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-06-04.
//  Copyright © 2026, all rights reserved.
//

import Nimble
import SwiftLMHostProtocol
import XCTest

@testable import SwiftLMCore
@testable import SwiftLMRuntime

private final class RecordingModelServer: ModelServer, @unchecked Sendable {
  let modelID: String
  let sizeBytes: Int64
  private let lock = NSLock()
  private var levels: [ThrottleLevel] = []

  var appliedLevels: [ThrottleLevel] {
    lock.lock()
    defer { lock.unlock() }
    return levels
  }

  init(modelID: String, sizeBytes: Int64) {
    self.modelID = modelID
    self.sizeBytes = sizeBytes
  }

  func spawn() {}
  func waitReady() {}

  func send(_ request: BackendRequest) -> AsyncThrowingStream<BackendFrame, Error> {
    AsyncThrowingStream { continuation in
      continuation.yield(.done(requestID: request.requestID))
      continuation.finish()
    }
  }

  func stats() -> BackendStats {
    BackendStats(rssBytes: 0, gpuActiveBytes: 0, gpuCacheBytes: 0)
  }

  func applyPowerThrottle(_ level: ThrottleLevel) {
    lock.lock()
    levels.append(level)
    lock.unlock()
  }

  func shutdown() {}
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
    expect(concurrency) == 2
    expect(pacing) == 75_000_000
  }

  func testHardCapsConcurrencyAndPaces() async {
    let router = makeRouter(embeddingMaxConcurrency: 4)
    await router.applyPowerThrottle(.hard)
    let concurrency = await router.embeddingMaxConcurrency
    let pacing = await router.embeddingPacing()
    expect(concurrency) == 1
    expect(pacing) == 250_000_000
  }

  func testNoneRestoresConfigured() async {
    let router = makeRouter(embeddingMaxConcurrency: 4)
    await router.applyPowerThrottle(.hard)
    await router.applyPowerThrottle(.none)
    let concurrency = await router.embeddingMaxConcurrency
    let pacing = await router.embeddingPacing()
    expect(concurrency) == 4
    expect(pacing) == 0
  }

  func testNeverRaisesAboveConfiguredCeiling() async {
    let router = makeRouter(embeddingMaxConcurrency: 1)
    await router.applyPowerThrottle(.mild)
    let concurrency = await router.embeddingMaxConcurrency
    expect(concurrency) == 1
  }

  func testUnboundedConfiguredUsesLevelCapThenRestoresToNil() async {
    let router = makeRouter(embeddingMaxConcurrency: nil)
    await router.applyPowerThrottle(.mild)
    let mild = await router.embeddingMaxConcurrency
    expect(mild) == 2
    await router.applyPowerThrottle(.none)
    let restored = await router.embeddingMaxConcurrency
    expect(restored) == nil
  }

  func testServerSpawnedWhileThrottledInheritsLevel() async throws {
    // Use mild: it forwards the level to a spawned server without halting
    // admission. (hard halts, so a model cannot be routed while it is active.)
    let server = RecordingModelServer(modelID: "/tmp/embed", sizeBytes: 0)
    let router = ModelRouter(
      reserveBytes: 0,
      memoryProbe: { MemoryReading(availableBytes: .max, underPressure: false) },
      spawner: { _, _, _ in server }
    )
    await router.applyPowerThrottle(.mild)
    let model = ModelDescriptor(
      id: "/tmp/embed", displayName: "embed", path: "/tmp/embed", sizeBytes: 0, kind: .embedding)
    _ = try await router.routeEmbeddingAndBegin(model)
    expect(server.appliedLevels) == [.mild]
  }

  // MARK: - Halt (refuse new, drain in-flight)

  func testHardHaltsAdmissionMildAndNoneDoNot() async {
    let router = makeRouter(embeddingMaxConcurrency: 4)
    let initial = await router.isPowerHalted()
    expect(initial) == false
    await router.applyPowerThrottle(.mild)
    let mild = await router.isPowerHalted()
    expect(mild) == false
    await router.applyPowerThrottle(.hard)
    let hard = await router.isPowerHalted()
    expect(hard) == true
    await router.applyPowerThrottle(.none)
    let cleared = await router.isPowerHalted()
    expect(cleared) == false
  }

  func testHardRefusesNewChatBeforeSpawning() async {
    let router = makeRouter(embeddingMaxConcurrency: 4)
    await router.applyPowerThrottle(.hard)
    let model = ModelDescriptor(
      id: "/tmp/chat", displayName: "chat", path: "/tmp/chat", sizeBytes: 0, kind: .chat)
    do {
      _ = try await router.routeAndBegin(model)
      fail("expected powerPaused")
    } catch let error as ModelRouter.RouteError {
      guard case .powerPaused(let reason) = error else {
        fail("expected powerPaused, got \(error)")
        return
      }
      expect(reason) == "battery"
    } catch {
      fail("unexpected error \(error)")
    }
  }

  func testHardRefusesNewEmbeddingBeforeSpawning() async {
    let router = ModelRouter(
      reserveBytes: 0,
      memoryProbe: { MemoryReading(availableBytes: .max, underPressure: false) },
      spawner: { _, _, _ in fatalError("spawner must not run while halted") }
    )
    await router.applyPowerThrottle(.hard)
    let model = ModelDescriptor(
      id: "/tmp/embed", displayName: "embed", path: "/tmp/embed", sizeBytes: 0, kind: .embedding)
    do {
      _ = try await router.routeEmbeddingAndBegin(model)
      fail("expected powerPaused")
    } catch let error as ModelRouter.RouteError {
      guard case .powerPaused(let reason) = error else {
        fail("expected powerPaused, got \(error)")
        return
      }
      expect(reason) == "battery"
    } catch {
      fail("unexpected error \(error)")
    }
  }
}
