//
//  ModelRouterTests.swift
//  SwiftLMRuntimeTests
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-04-18.
//  Copyright © 2026, all rights reserved.
//

import SwiftLMHostProtocol
import SwiftLMTrace
import XCTest

@testable import SwiftLMCore
@testable import SwiftLMRuntime

/// Minimal fake server that records lifecycle calls without spawning a process.
private final class FakeModelServer: ModelServer, @unchecked Sendable {
  let modelID: String
  let sizeBytes: Int64
  let kind: SwiftLMTrace.BackendKind

  private var stopped = false
  private var running = false
  private var spawned = false
  private var throttleLevels: [ThrottleLevel] = []

  var didSpawn: Bool {
    spawned
  }

  var didStop: Bool {
    stopped
  }

  var isRunning: Bool {
    running && !stopped
  }

  var appliedThrottleLevels: [ThrottleLevel] {
    throttleLevels
  }

  init(modelID: String, kind: SwiftLMTrace.BackendKind, sizeBytes: Int64) {
    self.modelID = modelID
    self.kind = kind
    self.sizeBytes = sizeBytes
  }

  func spawn() {
    spawned = true
    running = true
  }

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
    throttleLevels.append(level)
  }

  func shutdown() {
    stopped = true
    running = false
  }

  func markStoppedExternally() {
    running = false
  }
}

enum TestModelServerError: Error {
  case failed
}

/// A probe that always reports abundant memory and no pressure. Used by tests
/// that exercise routing behavior rather than the headroom guard.
private let abundantMemoryProbe: MemoryProbe = {
  MemoryReading(availableBytes: 1 << 50, underPressure: false)
}

/// Models system memory as a function of the fake servers still running, plus
/// an adjustable external-consumption knob and a pressure flag. Unloading a fake
/// frees its bytes, so the router's re-measure after eviction sees memory
/// recover, exactly as it would against the real system.
private final class MemoryModel: @unchecked Sendable {
  let totalBytes: Int64
  private let lock = NSLock()
  private var servers: [FakeModelServer] = []
  private var externalUsedBytes: Int64 = 0
  private var pressure = false

  init(totalGB: Int64) {
    self.totalBytes = totalGB * 1_073_741_824
  }

  func register(_ server: FakeModelServer) {
    lock.lock()
    servers.append(server)
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
      for server in servers where server.isRunning {
        used += server.sizeBytes
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
  ) -> (ModelRouter, () -> [FakeModelServer]) {
    let created = FakesBox()
    let spawner = makeRecordingSpawner(created: created, memory: model)
    let probe: MemoryProbe = model?.probe() ?? abundantMemoryProbe
    let router = ModelRouter(
      reserveBytes: reserveGB * gb,
      memoryProbe: probe,
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

  func testFirstRouteSpawnsServer() async throws {
    let (router, created) = makeRouter()
    let server = try await router.routeAndBegin(desc("A", 20))
    XCTAssertEqual(server.modelID, "A")
    XCTAssertEqual(created().count, 1)
    XCTAssertTrue(created().first?.didSpawn ?? false)
  }

  func testRepeatedRouteReusesServer() async throws {
    let (router, created) = makeRouter()
    _ = try await router.routeAndBegin(desc("A", 20))
    _ = try await router.routeAndBegin(desc("A", 20))
    _ = try await router.routeAndBegin(desc("A", 20))
    XCTAssertEqual(created().count, 1, "should only spawn once for the same model id")
  }

  func testRepeatedRoutePrunesStoppedServer() async throws {
    let (router, created) = makeRouter()
    let first = try await router.routeAndBegin(desc("A", 20))
    await router.requestDone(modelID: "A")
    created()[0].markStoppedExternally()

    let second = try await router.routeAndBegin(desc("A", 20))

    XCTAssertTrue(first !== second)
    XCTAssertEqual(created().count, 2, "stopped server should be replaced")
  }

  func testSecondModelSpawnsSecondServer() async throws {
    let (router, created) = makeRouter()
    let a = try await router.routeAndBegin(desc("A", 20))
    let b = try await router.routeAndBegin(desc("B", 20))
    XCTAssertFalse(a === b)
    XCTAssertEqual(created().count, 2)
  }

  func testAdmitsWhenMemorySafe() async throws {
    let memory = MemoryModel(totalGB: 100)
    let (router, created) = makeRouter(reserveGB: 20, model: memory)
    _ = try await router.routeAndBegin(desc("A", 40))
    XCTAssertEqual(created().count, 1)
    XCTAssertFalse(created()[0].didStop, "no eviction when memory is already safe")
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
    XCTAssertTrue(created()[0].didStop, "A should be evicted")
    XCTAssertFalse(created()[1].didStop, "B should still be alive")
    XCTAssertFalse(created()[2].didStop, "C should still be alive")
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
    XCTAssertTrue(created()[0].didStop, "idle A is unloaded to make room")
    XCTAssertFalse(created()[1].didStop, "B loads once memory recovers")
  }

  func testRefusesWhenEvictingAllIdleStillInsufficient() async throws {
    let memory = MemoryModel(totalGB: 60)
    let (router, created) = makeRouter(reserveGB: 20, model: memory)
    // A stays busy because no requestDone call releases it, so it can never be
    // evicted.
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
    XCTAssertFalse(created()[0].didStop, "busy model is never evicted")
  }

  func testPressureForcesEvictionEvenWhenBytesFine() async throws {
    let memory = MemoryModel(totalGB: 200)
    let (router, created) = makeRouter(reserveGB: 20, model: memory)
    _ = try await router.routeAndBegin(desc("A", 30))
    await router.requestDone(modelID: "A")
    // Byte count alone leaves plenty of room, but the system reports pressure.
    memory.setUnderPressure(true)
    _ = try await router.routeAndBegin(desc("B", 10))
    XCTAssertTrue(created()[0].didStop, "pressure forces the idle model to unload")
    XCTAssertFalse(created()[1].didStop, "B still loads after relief")
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
    XCTAssertTrue(created()[0].didStop, "idle A is unloaded to restore the reserve")
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

  func testShutdownAllStopsEveryServer() async throws {
    let (router, created) = makeRouter()
    _ = try await router.routeAndBegin(desc("A", 10))
    _ = try await router.routeAndBegin(desc("B", 10))
    await router.requestDone(modelID: "A")
    await router.requestDone(modelID: "B")
    await router.shutdownAll()
    XCTAssertTrue(created().allSatisfy(\.didStop))
  }

  func testUnloadAllowsNextServerToLoad() async throws {
    let (router, created) = makeRouter()
    _ = try await router.routeAndBegin(desc("A", 10))
    await router.requestDone(modelID: "A")
    await router.unload(modelID: "A")
    _ = try await router.routeAndBegin(desc("B", 10))
    XCTAssertEqual(created().count, 2)
    XCTAssertTrue(created()[0].didStop)
    XCTAssertFalse(created()[1].didStop)
  }

  func testRouterPublishesTypedLifecycleEvents() async throws {
    let events = RouterEventsBox()
    let (router, _) = makeRouter { event in
      events.append(event)
    }

    _ = try await router.routeAndBegin(desc("A", 10))
    await router.requestDone(modelID: "A")
    await router.unload(modelID: "A")

    XCTAssertEqual(
      events.getAll(),
      [
        .modelSpawned(modelID: "A", kind: .chat),
        .modelUnloaded(modelID: "A", kind: .chat),
      ]
    )
  }

  func testHeadroomEvictionPublishesModelEvictedLifecycleEvent() async throws {
    let events = RouterEventsBox()
    let memory = MemoryModel(totalGB: 80)
    let (router, created) = makeRouter(
      reserveGB: 0, model: memory
    ) { event in
      events.append(event)
    }

    _ = try await router.routeAndBegin(desc("A", 40))
    await router.requestDone(modelID: "A")
    _ = try await router.routeAndBegin(desc("B", 30))
    await router.requestDone(modelID: "B")
    _ = try await router.routeAndBegin(desc("C", 40))

    XCTAssertTrue(created()[0].didStop)
    XCTAssertEqual(
      events.getAll(),
      [
        .modelSpawned(modelID: "A", kind: .chat),
        .modelSpawned(modelID: "B", kind: .chat),
        .modelEvicted(modelID: "A", kind: .chat),
        .modelSpawned(modelID: "C", kind: .chat),
      ]
    )
  }

  func testHeadroomEvictionPublishesEmbeddingEvictedLifecycleEvent() async throws {
    let events = RouterEventsBox()
    let memory = MemoryModel(totalGB: 80)
    let embeddingModel = embeddingDesc("embed", 40)
    let spawner = makeRecordingSpawner(memory: memory)
    let router = ModelRouter(
      reserveBytes: 0,
      memoryProbe: memory.probe(),
      spawner: spawner,
      settleAttempts: 3,
      settleIntervalMillis: 1
    ) { event in
      events.append(event)
    }

    _ = try await router.routeEmbeddingAndBegin(embeddingModel)
    await router.embeddingRequestDone(modelID: embeddingModel.id)
    _ = try await router.routeAndBegin(desc("chat", 50))

    let snapshot = await router.snapshot()
    XCTAssertEqual(snapshot.loaded.map(\.modelID), ["chat"])
    XCTAssertEqual(
      events.getAll(),
      [
        .modelSpawned(modelID: "embed", kind: .embedding),
        .modelEvicted(modelID: "embed", kind: .embedding),
        .modelSpawned(modelID: "chat", kind: .chat),
      ]
    )
  }

  func testBrokerEventMapsRouterEvictionsToModelEvictedKind() {
    let modelEvent = BrokerEvent(routerEvent: .modelEvicted(modelID: "A", kind: .chat))
    XCTAssertEqual(modelEvent.kind, .modelEvicted)
    XCTAssertEqual(modelEvent.model, "A")
    XCTAssertEqual(modelEvent.message, "evicted chat model=A")

    let embeddingEvent = BrokerEvent(
      routerEvent: .modelEvicted(modelID: "embed", kind: .embedding))
    XCTAssertEqual(embeddingEvent.kind, .modelEvicted)
    XCTAssertEqual(embeddingEvent.model, "embed")
    XCTAssertEqual(embeddingEvent.message, "evicted embedding model=embed")
  }

  func testConcurrentEmbeddingRoutesShareLoadingTask() async throws {
    let model = embeddingDesc("embed", 10)
    let embeddingServer = FakeModelServer(
      modelID: model.id, kind: .embedding, sizeBytes: model.sizeBytes)
    let delayedSpawner = DelayedModelServerSpawner(server: embeddingServer)
    let router = ModelRouter(
      reserveBytes: 0,
      memoryProbe: abundantMemoryProbe,
      spawner: delayedSpawner.makeSpawner()
    )

    async let firstServer = router.routeEmbeddingAndBegin(model)
    await delayedSpawner.waitUntilStarted()
    async let secondServer = router.routeEmbeddingAndBegin(model)
    await Task.yield()
    await delayedSpawner.release()

    let routedServers = try await [firstServer, secondServer]
    XCTAssertTrue(routedServers[0] === routedServers[1])
    let delayedSpawnCount = await delayedSpawner.spawnCount()
    XCTAssertEqual(delayedSpawnCount, 1)

    let snapshot = await router.snapshot()
    XCTAssertEqual(snapshot.loaded.count, 1)
    XCTAssertEqual(snapshot.loaded.first?.inFlightRequests, 2)
  }

  func testEmbeddingLoadFailureClearsLoadingStateForRetry() async throws {
    let model = embeddingDesc("embed", 10)
    let embeddingServer = FakeModelServer(
      modelID: model.id, kind: .embedding, sizeBytes: model.sizeBytes)
    let retrySpawner = RetryModelServerSpawner(server: embeddingServer)
    let router = ModelRouter(
      reserveBytes: 0,
      memoryProbe: abundantMemoryProbe,
      spawner: retrySpawner.makeSpawner()
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

    let routedServer = try await router.routeEmbeddingAndBegin(model)
    XCTAssertTrue(routedServer === embeddingServer)
    let retrySpawnCount = await retrySpawner.spawnCount()
    XCTAssertEqual(retrySpawnCount, 2)
  }

  // MARK: - Concurrency queue

  private func makeChatRouter(chatMaxConcurrency: Int) -> ModelRouter {
    ModelRouter(
      reserveBytes: 0,
      memoryProbe: abundantMemoryProbe,
      spawner: makeRecordingSpawner(),
      chatMaxConcurrency: chatMaxConcurrency
    )
  }

  private func makeEmbeddingRouter(embeddingMaxConcurrency: Int) -> ModelRouter {
    ModelRouter(
      reserveBytes: 0,
      memoryProbe: abundantMemoryProbe,
      spawner: makeRecordingSpawner(),
      embeddingMaxConcurrency: embeddingMaxConcurrency
    )
  }

  func testChatContentionQueuesThenProceeds() async throws {
    let router = makeChatRouter(chatMaxConcurrency: 1)
    let model = desc("A", 10)
    _ = try await router.routeAndBegin(model)  // holds the only slot

    async let second = router.routeAndBegin(model)
    for _ in 0..<20 { await Task.yield() }
    var snapshot = await router.snapshot()
    XCTAssertEqual(
      snapshot.loaded.first?.inFlightRequests, 1, "second request should queue, not be admitted")

    await router.requestDone(modelID: model.id)
    _ = try await second
    snapshot = await router.snapshot()
    XCTAssertEqual(snapshot.loaded.first?.inFlightRequests, 1)
  }

  func testEmbeddingContentionQueuesThenProceeds() async throws {
    let router = makeEmbeddingRouter(embeddingMaxConcurrency: 1)
    let model = embeddingDesc("embed", 10)
    _ = try await router.routeEmbeddingAndBegin(model)  // loads, holds the only slot

    async let second = router.routeEmbeddingAndBegin(model)
    for _ in 0..<20 { await Task.yield() }
    var snapshot = await router.snapshot()
    XCTAssertEqual(snapshot.loaded.first?.inFlightRequests, 1)

    await router.embeddingRequestDone(modelID: model.id)
    _ = try await second
    snapshot = await router.snapshot()
    XCTAssertEqual(snapshot.loaded.first?.inFlightRequests, 1)
  }

  func testChatQueueTimeoutSurfacesConcurrencyLimit() async throws {
    let router = makeChatRouter(chatMaxConcurrency: 1)
    await router.setQueueTimeoutNanos(50_000_000)
    let model = desc("A", 10)
    _ = try await router.routeAndBegin(model)  // never released

    do {
      _ = try await router.routeAndBegin(model)
      XCTFail("expected concurrencyLimitExceeded after the queue wait timed out")
    } catch let error as ModelRouter.RouteError {
      guard case .concurrencyLimitExceeded = error else {
        XCTFail("expected concurrencyLimitExceeded, got \(error)")
        return
      }
    }
  }

  func testEmbeddingQueueTimeoutSurfacesConcurrencyLimit() async throws {
    let router = makeEmbeddingRouter(embeddingMaxConcurrency: 1)
    await router.setQueueTimeoutNanos(50_000_000)
    let model = embeddingDesc("embed", 10)
    _ = try await router.routeEmbeddingAndBegin(model)  // never released

    do {
      _ = try await router.routeEmbeddingAndBegin(model)
      XCTFail("expected concurrencyLimitExceeded after the queue wait timed out")
    } catch let error as ModelRouter.RouteError {
      guard case .concurrencyLimitExceeded = error else {
        XCTFail("expected concurrencyLimitExceeded, got \(error)")
        return
      }
    }
  }

  func testChatDefaultWidthAdmitsUpToLimitThenQueues() async throws {
    let router = makeChatRouter(chatMaxConcurrency: 4)
    await router.setQueueTimeoutNanos(50_000_000)
    let model = desc("A", 10)
    for _ in 0..<4 {
      _ = try await router.routeAndBegin(model)  // four admitted without waiting
    }
    let snapshot = await router.snapshot()
    XCTAssertEqual(snapshot.loaded.first?.inFlightRequests, 4)

    do {
      _ = try await router.routeAndBegin(model)  // fifth queues, then times out
      XCTFail("expected the fifth request to queue and time out")
    } catch let error as ModelRouter.RouteError {
      guard case .concurrencyLimitExceeded = error else {
        XCTFail("expected concurrencyLimitExceeded, got \(error)")
        return
      }
    }
  }

  func testUnloadDrainsQueuedWaiter() async throws {
    let router = makeChatRouter(chatMaxConcurrency: 1)
    let model = desc("A", 10)
    _ = try await router.routeAndBegin(model)

    async let second = router.routeAndBegin(model)
    try await Task.sleep(nanoseconds: 50_000_000)  // let the second request queue
    await router.unload(modelID: model.id)

    do {
      _ = try await second
      XCTFail("expected the drained waiter to surface an error rather than hang")
    } catch is ModelRouter.RouteError {
      // Expected: a drained waiter resolves instead of hanging.
    }
  }

  func testChatWaitersWakeInFifoOrder() async throws {
    let router = makeChatRouter(chatMaxConcurrency: 1)
    let model = desc("A", 10)
    _ = try await router.routeAndBegin(model)  // holds the only slot

    let order = OrderRecorder()
    async let w0: Void = acquireThenRecord(router: router, model: model, index: 0, order: order)
    try await Task.sleep(nanoseconds: 20_000_000)
    async let w1: Void = acquireThenRecord(router: router, model: model, index: 1, order: order)
    try await Task.sleep(nanoseconds: 20_000_000)
    async let w2: Void = acquireThenRecord(router: router, model: model, index: 2, order: order)
    try await Task.sleep(nanoseconds: 20_000_000)

    for _ in 0..<3 {
      await router.requestDone(modelID: model.id)
      try await Task.sleep(nanoseconds: 20_000_000)
    }
    _ = await [w0, w1, w2]
    let recorded = await order.values()
    XCTAssertEqual(recorded, [0, 1, 2])
  }
}

private actor OrderRecorder {
  private var recorded: [Int] = []
  func append(_ value: Int) { recorded.append(value) }
  func values() -> [Int] { recorded }
}

/// Acquire a chat slot then record `index`. A free function so `async let` does
/// not send the non-Sendable test case across a concurrency boundary.
private func acquireThenRecord(
  router: ModelRouter,
  model: ModelDescriptor,
  index: Int,
  order: OrderRecorder
) async {
  do {
    _ = try await router.routeAndBegin(model)
    await order.append(index)
  } catch {
    // The FIFO test never exercises the failure path.
  }
}

private actor DelayedModelServerSpawner {
  private let server: FakeModelServer
  private var startedContinuation: CheckedContinuation<Void, Never>?
  private var releaseContinuation: CheckedContinuation<Void, Never>?
  private var hasStarted = false
  private var count = 0

  init(server: FakeModelServer) {
    self.server = server
  }

  nonisolated func makeSpawner() -> ModelServerSpawner {
    { model, kind, _ in
      try await self.spawn(model: model, kind: kind)
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

  private func spawn(
    model _: ModelDescriptor,
    kind _: SwiftLMTrace.BackendKind
  ) async throws -> ModelServer {
    count += 1
    hasStarted = true
    startedContinuation?.resume()
    startedContinuation = nil
    await withCheckedContinuation { continuation in
      releaseContinuation = continuation
    }
    try await server.spawn()
    try await server.waitReady()
    return server
  }
}

private actor RetryModelServerSpawner {
  private let server: FakeModelServer
  private var count = 0

  init(server: FakeModelServer) {
    self.server = server
  }

  nonisolated func makeSpawner() -> ModelServerSpawner {
    { model, kind, _ in
      try await self.spawn(model: model, kind: kind)
    }
  }

  func spawnCount() -> Int {
    count
  }

  private func spawn(
    model _: ModelDescriptor,
    kind _: SwiftLMTrace.BackendKind
  ) async throws -> ModelServer {
    count += 1
    if count == 1 {
      throw TestModelServerError.failed
    }
    try await server.spawn()
    try await server.waitReady()
    return server
  }
}

private func makeRecordingSpawner(
  created: FakesBox? = nil,
  memory: MemoryModel? = nil
) -> ModelServerSpawner {
  { model, kind, _ in
    let server = FakeModelServer(modelID: model.id, kind: kind, sizeBytes: model.sizeBytes)
    created?.append(server)
    memory?.register(server)
    try await server.spawn()
    try await server.waitReady()
    return server
  }
}

/// Small thread-safe list wrapper used to observe spawner output from outside.
private final class FakesBox: @unchecked Sendable {
  private var items: [FakeModelServer] = []
  private let lock = NSLock()
  func append(_ item: FakeModelServer) {
    lock.lock()
    items.append(item)
    lock.unlock()
  }
  func getAll() -> [FakeModelServer] {
    lock.lock()
    defer { lock.unlock() }
    return items
  }
}

private final class RouterEventsBox: @unchecked Sendable {
  private var items: [RouterLifecycleEvent] = []
  private let lock = NSLock()
  func append(_ item: RouterLifecycleEvent) {
    lock.lock()
    items.append(item)
    lock.unlock()
  }
  func getAll() -> [RouterLifecycleEvent] {
    lock.lock()
    defer { lock.unlock() }
    return items
  }
}
