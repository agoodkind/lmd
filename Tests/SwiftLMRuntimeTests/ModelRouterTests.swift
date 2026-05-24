//
//  ModelRouterTests.swift
//  SwiftLMRuntimeTests
//
//  Created by Alex Goodkind <alex@goodkind.io> on 2026-04-18.
//  Copyright © 2026
//

import XCTest
@testable import SwiftLMBackend
@testable import SwiftLMCore
@testable import SwiftLMRuntime

/// Minimal fake backend that records lifecycle calls without spawning a process.
private final class FakeBackend: SwiftLMBackendProtocol, @unchecked Sendable {
  let modelID: String
  let port: Int
  let sizeBytes: Int64
  var launched = false
  var stopped = false
  var running = false
  var isRunning: Bool { running && !stopped }

  init(modelID: String, port: Int, sizeBytes: Int64) {
    self.modelID = modelID
    self.port = port
    self.sizeBytes = sizeBytes
  }

  func launch() throws {
    launched = true
    running = true
  }
  func shutdown() {
    stopped = true
    running = false
  }
}

private final class FakeEmbeddingBackend: EmbeddingBackendProtocol, @unchecked Sendable {
  let modelID: String
  let sizeBytes: Int64
  var stopped = false

  init(modelID: String, sizeBytes: Int64) {
    self.modelID = modelID
    self.sizeBytes = sizeBytes
  }

  func launch() async throws {}
  func shutdown() { stopped = true }
  func embed(inputs: [String]) async throws -> [[Float]] {
    inputs.map { _ in [0.0] }
  }
}

enum TestEmbeddingError: Error {
  case failed
}

final class ModelRouterTests: XCTestCase {
  private let gb: Int64 = 1_073_741_824

  private func makeRouter(
    ceiling: Int64 = 80,
    reserve: Int64 = 0,
    eventSink: @escaping @Sendable (RouterLifecycleEvent) -> Void = { _ in }
  ) -> (ModelRouter, () -> [FakeBackend]) {
    let created = FakesBox()
    let spawner: BackendSpawner = { model, port, _ in
      let fake = FakeBackend(modelID: model.id, port: port, sizeBytes: model.sizeBytes)
      created.append(fake)
      return fake
    }
    let budget = MemoryBudget(
      ceilingBytes: ceiling * 1_073_741_824,
      reservedBytes: reserve * 1_073_741_824
    )
    let router = ModelRouter(
      budget: budget,
      portRange: 5500...5502,
      spawner: spawner,
      eventSink: eventSink
    )
    return (router, created.getAll)
  }

  /// Helper to descriptor from a name and size in GB.
  private func desc(_ name: String, _ sizeGB: Int64) -> ModelDescriptor {
    ModelDescriptor(id: name, displayName: name, path: "/tmp/\(name)", sizeBytes: sizeGB * gb)
  }

  private func embeddingDesc(_ name: String, _ sizeGB: Int64) -> ModelDescriptor {
    ModelDescriptor(
      id: name,
      displayName: name,
      path: "/tmp/\(name)",
      sizeBytes: sizeGB * gb,
      kind: .embedding
    )
  }

  func testFirstRouteSpawnsBackend() async throws {
    let (router, created) = makeRouter()
    let backend = try await router.routeAndBegin(desc("A", 20))
    XCTAssertEqual(backend.modelID, "A")
    XCTAssertEqual(backend.port, 5500)
    XCTAssertEqual(created().count, 1)
    XCTAssertTrue(created().first?.launched ?? false)
  }

  func testRepeatedRouteReusesBackend() async throws {
    let (router, created) = makeRouter()
    _ = try await router.routeAndBegin(desc("A", 20))
    _ = try await router.routeAndBegin(desc("A", 20))
    _ = try await router.routeAndBegin(desc("A", 20))
    XCTAssertEqual(created().count, 1, "should only spawn once for the same model id")
  }

  func testRepeatedRoutePrunesStoppedBackend() async throws {
    let (router, created) = makeRouter()
    let first = try await router.routeAndBegin(desc("A", 20))
    await router.requestDone(modelID: "A")
    created()[0].running = false

    let second = try await router.routeAndBegin(desc("A", 20))

    XCTAssertEqual(first.port, 5500)
    XCTAssertEqual(second.port, 5500)
    XCTAssertEqual(created().count, 2, "stopped backend should be replaced")
  }

  func testSecondModelAllocatesSecondPort() async throws {
    let (router, created) = makeRouter()
    let a = try await router.routeAndBegin(desc("A", 20))
    let b = try await router.routeAndBegin(desc("B", 20))
    XCTAssertEqual(a.port, 5500)
    XCTAssertEqual(b.port, 5501)
    XCTAssertEqual(created().count, 2)
  }

  func testEvictsOldestIdleWhenBudgetExceeded() async throws {
    let (router, created) = makeRouter(ceiling: 80)  // 80 usable
    let a = try await router.routeAndBegin(desc("A", 40))
    await router.requestDone(modelID: "A")
    let b = try await router.routeAndBegin(desc("B", 30))
    await router.requestDone(modelID: "B")
    let c = try await router.routeAndBegin(desc("C", 40))
    await router.requestDone(modelID: "C")
    XCTAssertEqual(created().count, 3)
    XCTAssertTrue(created()[0].stopped, "A should be evicted")
    XCTAssertFalse(created()[1].stopped, "B should still be alive")
    XCTAssertFalse(created()[2].stopped, "C should still be alive")
    _ = a; _ = b; _ = c
  }

  func testThrowsWhenCannotFit() async throws {
    let (router, _) = makeRouter(ceiling: 20)
    do {
      _ = try await router.routeAndBegin(desc("Huge", 50))
      XCTFail("expected error")
    } catch let err as ModelRouter.RouteError {
      if case .cannotFitInBudget = err {
        return
      }
      XCTFail("expected cannotFitInBudget, got \(err)")
    }
  }

  func testShutdownAllStopsEveryBackend() async throws {
    let (router, created) = makeRouter()
    _ = try await router.routeAndBegin(desc("A", 10))
    _ = try await router.routeAndBegin(desc("B", 10))
    await router.requestDone(modelID: "A")
    await router.requestDone(modelID: "B")
    await router.shutdownAll()
    XCTAssertTrue(created().allSatisfy { $0.stopped })
  }

  func testUnloadsFreePorts() async throws {
    let (router, _) = makeRouter()
    _ = try await router.routeAndBegin(desc("A", 10))
    await router.requestDone(modelID: "A")
    await router.unload(modelID: "A")
    let next = try await router.routeAndBegin(desc("B", 10))
    XCTAssertEqual(next.port, 5500)
  }

  func testRouterPublishesTypedLifecycleEvents() async throws {
    let events = RouterEventsBox()
    let (router, _) = makeRouter(eventSink: { event in
      events.append(event)
    })

    _ = try await router.routeAndBegin(desc("A", 10))
    await router.requestDone(modelID: "A")
    await router.unload(modelID: "A")

    XCTAssertEqual(
      events.getAll(),
      [
        .modelSpawned(modelID: "A", port: 5500),
        .modelUnloaded(modelID: "A", port: 5500),
      ]
    )
  }

  func testBudgetEvictionPublishesModelEvictedLifecycleEvent() async throws {
    let events = RouterEventsBox()
    let (router, created) = makeRouter(ceiling: 80, eventSink: { event in
      events.append(event)
    })

    _ = try await router.routeAndBegin(desc("A", 40))
    await router.requestDone(modelID: "A")
    _ = try await router.routeAndBegin(desc("B", 30))
    await router.requestDone(modelID: "B")
    _ = try await router.routeAndBegin(desc("C", 40))

    XCTAssertTrue(created()[0].stopped)
    XCTAssertEqual(
      events.getAll(),
      [
        .modelSpawned(modelID: "A", port: 5500),
        .modelSpawned(modelID: "B", port: 5501),
        .modelEvicted(modelID: "A", port: 5500),
        .modelSpawned(modelID: "C", port: 5500),
      ]
    )
  }

  func testBudgetEvictionPublishesEmbeddingEvictedLifecycleEvent() async throws {
    let events = RouterEventsBox()
    let embeddingModel = embeddingDesc("embed", 40)
    let embeddingBackend = FakeEmbeddingBackend(
      modelID: embeddingModel.id,
      sizeBytes: embeddingModel.sizeBytes
    )
    let router = ModelRouter(
      budget: MemoryBudget(ceilingBytes: 80 * gb),
      portRange: 5500...5502,
      spawner: { model, port, _ in
        FakeBackend(modelID: model.id, port: port, sizeBytes: model.sizeBytes)
      },
      embeddingSpawner: { _, _ in embeddingBackend },
      eventSink: { event in
        events.append(event)
      }
    )

    _ = try await router.routeEmbeddingAndBegin(embeddingModel)
    await router.embeddingRequestDone(modelID: embeddingModel.id)
    _ = try await router.routeAndBegin(desc("chat", 50))

    XCTAssertTrue(embeddingBackend.stopped)
    XCTAssertEqual(
      events.getAll(),
      [
        .embeddingSpawned(modelID: "embed"),
        .embeddingEvicted(modelID: "embed"),
        .modelSpawned(modelID: "chat", port: 5500),
      ]
    )
  }

  func testBrokerEventMapsRouterEvictionsToModelEvictedKind() {
    let modelEvent = BrokerEvent(routerEvent: .modelEvicted(modelID: "A", port: 5500))
    XCTAssertEqual(modelEvent.kind, .modelEvicted)
    XCTAssertEqual(modelEvent.model, "A")
    XCTAssertEqual(modelEvent.message, "evicted model=A port=5500")

    let embeddingEvent = BrokerEvent(routerEvent: .embeddingEvicted(modelID: "embed"))
    XCTAssertEqual(embeddingEvent.kind, .modelEvicted)
    XCTAssertEqual(embeddingEvent.model, "embed")
    XCTAssertEqual(embeddingEvent.message, "evicted embedding model=embed")
  }

  func testConcurrentEmbeddingRoutesShareLoadingTask() async throws {
    let model = embeddingDesc("embed", 10)
    let embeddingBackend = FakeEmbeddingBackend(modelID: model.id, sizeBytes: model.sizeBytes)
    let delayedSpawner = DelayedEmbeddingSpawner(backend: embeddingBackend)
    let router = ModelRouter(
      budget: MemoryBudget(ceilingBytes: 80 * gb),
      spawner: { model, port, _ in
        FakeBackend(modelID: model.id, port: port, sizeBytes: model.sizeBytes)
      },
      embeddingSpawner: delayedSpawner.makeSpawner()
    )

    async let firstBackend = router.routeEmbeddingAndBegin(model)
    await delayedSpawner.waitUntilStarted()
    async let secondBackend = router.routeEmbeddingAndBegin(model)
    await Task.yield()
    await delayedSpawner.release()

    let routedBackends = try await [firstBackend, secondBackend]
    XCTAssertTrue(routedBackends[0] === routedBackends[1])
    let delayedSpawnCount = await delayedSpawner.spawnCount()
    XCTAssertEqual(delayedSpawnCount, 1)

    let snapshot = await router.snapshot()
    XCTAssertEqual(snapshot.loaded.count, 1)
    XCTAssertEqual(snapshot.loaded.first?.inFlightRequests, 2)
  }

  func testEmbeddingLoadFailureClearsLoadingStateForRetry() async throws {
    let model = embeddingDesc("embed", 10)
    let embeddingBackend = FakeEmbeddingBackend(modelID: model.id, sizeBytes: model.sizeBytes)
    let retrySpawner = RetryEmbeddingSpawner(backend: embeddingBackend)
    let router = ModelRouter(
      budget: MemoryBudget(ceilingBytes: 80 * gb),
      spawner: { model, port, _ in
        FakeBackend(modelID: model.id, port: port, sizeBytes: model.sizeBytes)
      },
      embeddingSpawner: retrySpawner.makeSpawner()
    )

    do {
      _ = try await router.routeEmbeddingAndBegin(model)
      XCTFail("expected first embedding load to fail")
    } catch let error as ModelRouter.RouteError {
      guard case .backendLaunchFailed = error else {
        XCTFail("expected backendLaunchFailed, got \(error)")
        return
      }
    }

    let routedBackend = try await router.routeEmbeddingAndBegin(model)
    XCTAssertTrue(routedBackend === embeddingBackend)
    let retrySpawnCount = await retrySpawner.spawnCount()
    XCTAssertEqual(retrySpawnCount, 2)
  }
}

private actor DelayedEmbeddingSpawner {
  private let backend: FakeEmbeddingBackend
  private var startedContinuation: CheckedContinuation<Void, Never>?
  private var releaseContinuation: CheckedContinuation<Void, Never>?
  private var hasStarted = false
  private var count = 0

  init(backend: FakeEmbeddingBackend) {
    self.backend = backend
  }

  nonisolated func makeSpawner() -> EmbeddingSpawner {
    { model, _ in
      try await self.spawn(model: model)
    }
  }

  func waitUntilStarted() async {
    if hasStarted {
      return
    }
    await withCheckedContinuation { continuation in
      startedContinuation = continuation
    }
  }

  func release() {
    releaseContinuation?.resume()
    releaseContinuation = nil
  }

  func spawnCount() -> Int {
    count
  }

  private func spawn(model: ModelDescriptor) async throws -> EmbeddingBackendProtocol {
    count += 1
    hasStarted = true
    startedContinuation?.resume()
    startedContinuation = nil
    await withCheckedContinuation { continuation in
      releaseContinuation = continuation
    }
    return backend
  }
}

private actor RetryEmbeddingSpawner {
  private let backend: FakeEmbeddingBackend
  private var count = 0

  init(backend: FakeEmbeddingBackend) {
    self.backend = backend
  }

  nonisolated func makeSpawner() -> EmbeddingSpawner {
    { model, _ in
      try await self.spawn(model: model)
    }
  }

  func spawnCount() -> Int {
    count
  }

  private func spawn(model: ModelDescriptor) async throws -> EmbeddingBackendProtocol {
    count += 1
    if count == 1 {
      throw TestEmbeddingError.failed
    }
    return backend
  }
}

/// Small thread-safe list wrapper used to observe spawner output from outside.
private final class FakesBox: @unchecked Sendable {
  private var items: [FakeBackend] = []
  private let lock = NSLock()
  func append(_ item: FakeBackend) { lock.lock(); items.append(item); lock.unlock() }
  func getAll() -> [FakeBackend] { lock.lock(); defer { lock.unlock() }; return items }
}

private final class RouterEventsBox: @unchecked Sendable {
  private var items: [RouterLifecycleEvent] = []
  private let lock = NSLock()
  func append(_ item: RouterLifecycleEvent) { lock.lock(); items.append(item); lock.unlock() }
  func getAll() -> [RouterLifecycleEvent] { lock.lock(); defer { lock.unlock() }; return items }
}
