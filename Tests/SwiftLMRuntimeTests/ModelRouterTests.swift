//
//  ModelRouterTests.swift
//  SwiftLMRuntimeTests
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-04-18.
//  Copyright © 2026, all rights reserved.
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

/// A probe that always reports abundant memory and no pressure. Used by tests
/// that exercise routing and ports rather than the headroom guard.
private let abundantMemoryProbe: MemoryProbe = {
  MemoryReading(availableBytes: 1 << 50, underPressure: false)
}

/// Models system memory as a function of the fake backends still running, plus
/// an adjustable external-consumption knob and a pressure flag. Unloading a fake
/// (which sets it stopped) frees its bytes, so the router's re-measure after
/// eviction sees memory recover, exactly as it would against the real system.
private final class MemoryModel: @unchecked Sendable {
  let totalBytes: Int64
  private let lock = NSLock()
  private var chat: [FakeBackend] = []
  private var embed: [FakeEmbeddingBackend] = []
  private var externalUsedBytes: Int64 = 0
  private var pressure = false

  init(totalGB: Int64) {
    self.totalBytes = totalGB * 1_073_741_824
  }

  func registerChat(_ backend: FakeBackend) {
    lock.lock()
    chat.append(backend)
    lock.unlock()
  }

  func registerEmbed(_ backend: FakeEmbeddingBackend) {
    lock.lock()
    embed.append(backend)
    lock.unlock()
  }

  func setExternalUsed(gb: Int64) {
    lock.lock()
    externalUsedBytes = gb * 1_073_741_824
    lock.unlock()
  }

  func setUnderPressure(_ value: Bool) {
    lock.lock()
    pressure = value
    lock.unlock()
  }

  func probe() -> MemoryProbe {
    { [self] in
      lock.lock()
      defer { lock.unlock() }
      var used = externalUsedBytes
      for backend in chat where backend.isRunning {
        used += backend.sizeBytes
      }
      for backend in embed where !backend.stopped {
        used += backend.sizeBytes
      }
      return MemoryReading(availableBytes: max(0, totalBytes - used), underPressure: pressure)
    }
  }
}

final class ModelRouterTests: XCTestCase {
  private let gb: Int64 = 1_073_741_824

  private func makeRouter(
    reserveGB: Int64 = 0,
    model: MemoryModel? = nil,
    eventSink: @escaping @Sendable (RouterLifecycleEvent) -> Void = { _ in }
  ) -> (ModelRouter, () -> [FakeBackend]) {
    let created = FakesBox()
    let spawner: BackendSpawner = { model2, port, _ in
      let fake = FakeBackend(modelID: model2.id, port: port, sizeBytes: model2.sizeBytes)
      created.append(fake)
      model?.registerChat(fake)
      return fake
    }
    let probe: MemoryProbe = model?.probe() ?? abundantMemoryProbe
    let router = ModelRouter(
      reserveBytes: reserveGB * gb,
      memoryProbe: probe,
      portRange: 5500...5502,
      spawner: spawner,
      settleAttempts: 3,
      settleIntervalMillis: 1,
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

  func testAdmitsWhenMemorySafe() async throws {
    let memory = MemoryModel(totalGB: 100)
    let (router, created) = makeRouter(reserveGB: 20, model: memory)
    _ = try await router.routeAndBegin(desc("A", 40))
    XCTAssertEqual(created().count, 1)
    XCTAssertFalse(created()[0].stopped, "no eviction when memory is already safe")
  }

  func testEvictsOldestIdleWhenHeadroomExceeded() async throws {
    let memory = MemoryModel(totalGB: 80)
    let (router, created) = makeRouter(reserveGB: 0, model: memory)
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
    _ = a
    _ = b
    _ = c
  }

  func testAdmitsAfterEvictingIdleModelWhenMemoryRecovers() async throws {
    let memory = MemoryModel(totalGB: 60)
    let (router, created) = makeRouter(reserveGB: 20, model: memory)
    _ = try await router.routeAndBegin(desc("A", 30))
    await router.requestDone(modelID: "A")
    _ = try await router.routeAndBegin(desc("B", 30))
    XCTAssertEqual(created().count, 2)
    XCTAssertTrue(created()[0].stopped, "idle A is unloaded to make room")
    XCTAssertFalse(created()[1].stopped, "B loads once memory recovers")
  }

  func testRefusesWhenEvictingAllIdleStillInsufficient() async throws {
    let memory = MemoryModel(totalGB: 60)
    let (router, created) = makeRouter(reserveGB: 20, model: memory)
    // A stays busy (no requestDone), so it can never be evicted.
    _ = try await router.routeAndBegin(desc("A", 40))
    do {
      _ = try await router.routeAndBegin(desc("B", 30))
      XCTFail("expected insufficientHeadroom")
    } catch let err as ModelRouter.RouteError {
      guard case .insufficientHeadroom = err else {
        XCTFail("expected insufficientHeadroom, got \(err)")
        return
      }
    }
    XCTAssertFalse(created()[0].stopped, "busy model is never evicted")
  }

  func testPressureForcesEvictionEvenWhenBytesFine() async throws {
    let memory = MemoryModel(totalGB: 200)
    let (router, created) = makeRouter(reserveGB: 20, model: memory)
    _ = try await router.routeAndBegin(desc("A", 30))
    await router.requestDone(modelID: "A")
    // Byte count alone leaves plenty of room, but the system reports pressure.
    memory.setUnderPressure(true)
    _ = try await router.routeAndBegin(desc("B", 10))
    XCTAssertTrue(created()[0].stopped, "pressure forces the idle model to unload")
    XCTAssertFalse(created()[1].stopped, "B still loads after relief")
  }

  func testEnforceHeadroomFreesIdleUnderExternalPressure() async throws {
    let memory = MemoryModel(totalGB: 100)
    let (router, created) = makeRouter(reserveGB: 20, model: memory)
    _ = try await router.routeAndBegin(desc("A", 30))
    await router.requestDone(modelID: "A")
    // An external process consumes memory after A was admitted, dropping free
    // memory below the reserve with no load event to trigger the check.
    memory.setExternalUsed(gb: 70)
    await router.enforceHeadroom()
    XCTAssertTrue(created()[0].stopped, "idle A is unloaded to restore the reserve")
  }

  func testThrowsWhenCannotFit() async throws {
    let memory = MemoryModel(totalGB: 20)
    let (router, _) = makeRouter(reserveGB: 0, model: memory)
    do {
      _ = try await router.routeAndBegin(desc("Huge", 50))
      XCTFail("expected error")
    } catch let err as ModelRouter.RouteError {
      if case .insufficientHeadroom = err {
        return
      }
      XCTFail("expected insufficientHeadroom, got \(err)")
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

  func testHeadroomEvictionPublishesModelEvictedLifecycleEvent() async throws {
    let events = RouterEventsBox()
    let memory = MemoryModel(totalGB: 80)
    let (router, created) = makeRouter(
      reserveGB: 0, model: memory,
      eventSink: { event in
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

  func testHeadroomEvictionPublishesEmbeddingEvictedLifecycleEvent() async throws {
    let events = RouterEventsBox()
    let memory = MemoryModel(totalGB: 80)
    let embeddingModel = embeddingDesc("embed", 40)
    let embeddingBackend = FakeEmbeddingBackend(
      modelID: embeddingModel.id,
      sizeBytes: embeddingModel.sizeBytes
    )
    let router = ModelRouter(
      reserveBytes: 0,
      memoryProbe: memory.probe(),
      portRange: 5500...5502,
      spawner: { model, port, _ in
        FakeBackend(modelID: model.id, port: port, sizeBytes: model.sizeBytes)
      },
      embeddingSpawner: { _, _ in
        memory.registerEmbed(embeddingBackend)
        return embeddingBackend
      },
      settleAttempts: 3,
      settleIntervalMillis: 1,
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
      reserveBytes: 0,
      memoryProbe: abundantMemoryProbe,
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
      reserveBytes: 0,
      memoryProbe: abundantMemoryProbe,
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
