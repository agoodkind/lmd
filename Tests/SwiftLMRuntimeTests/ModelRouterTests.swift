//
//  ModelRouterTests.swift
//  SwiftLMRuntimeTests
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-04-18.
//  Copyright © 2026, all rights reserved.
//

import Nimble
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
      requestWaitTimeoutMillis: 200,
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
    expect(server.modelID) == "A"
    expect(created().count) == 1
    expect(created().first?.didSpawn ?? false) == true
  }

  func testRepeatedRouteReusesServer() async throws {
    let (router, created) = makeRouter()
    _ = try await router.routeAndBegin(desc("A", 20))
    _ = try await router.routeAndBegin(desc("A", 20))
    _ = try await router.routeAndBegin(desc("A", 20))
    expect(created().count) == 1
  }

  func testRepeatedRoutePrunesStoppedServer() async throws {
    let (router, created) = makeRouter()
    let first = try await router.routeAndBegin(desc("A", 20))
    await router.requestDone(modelID: "A")
    created()[0].markStoppedExternally()

    let second = try await router.routeAndBegin(desc("A", 20))

    expect(first !== second) == true
    expect(created().count) == 2
  }

  func testSecondModelSpawnsSecondServer() async throws {
    let (router, created) = makeRouter()
    let a = try await router.routeAndBegin(desc("A", 20))
    let b = try await router.routeAndBegin(desc("B", 20))
    expect(a === b) == false
    expect(created().count) == 2
  }

  func testAdmitsWhenMemorySafe() async throws {
    let memory = MemoryModel(totalGB: 100)
    let (router, created) = makeRouter(reserveGB: 20, model: memory)
    _ = try await router.routeAndBegin(desc("A", 40))
    expect(created().count) == 1
    expect(created()[0].didStop) == false
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
    expect(created().count) == 3
    expect(created()[0].didStop) == true
    expect(created()[1].didStop) == false
    expect(created()[2].didStop) == false
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
    expect(created().count) == 2
    expect(created()[0].didStop) == true
    expect(created()[1].didStop) == false
  }

  func testRefusesWhenEvictingAllIdleStillInsufficient() async throws {
    let memory = MemoryModel(totalGB: 60)
    let (router, created) = makeRouter(reserveGB: 20, model: memory)
    // A stays busy because no requestDone call releases it, so it can never be
    // evicted.
    _ = try await router.routeAndBegin(desc("A", 40))
    do {
      _ = try await router.routeAndBegin(desc("B", 30))
      fail("expected insufficientHeadroom")
    } catch let err as ModelRouter.RouteError {
      guard case .insufficientHeadroom = err else {
        fail("expected insufficientHeadroom, got \(err)")
        return
      }
    }
    expect(created()[0].didStop) == false
  }

  func testPressureForcesEvictionEvenWhenBytesFine() async throws {
    let memory = MemoryModel(totalGB: 200)
    let (router, created) = makeRouter(reserveGB: 20, model: memory)
    _ = try await router.routeAndBegin(desc("A", 30))
    await router.requestDone(modelID: "A")
    // Byte count alone leaves plenty of room, but the system reports pressure.
    memory.setUnderPressure(true)
    _ = try await router.routeAndBegin(desc("B", 10))
    expect(created()[0].didStop) == true
    expect(created()[1].didStop) == false
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
    expect(created()[0].didStop) == true
  }

  func testThrowsWhenCannotFit() async throws {
    let memory = MemoryModel(totalGB: 20)
    let (router, _) = makeRouter(reserveGB: 0, model: memory)
    do {
      _ = try await router.routeAndBegin(desc("Huge", 50))
      fail("expected error")
    } catch let err as ModelRouter.RouteError {
      if case .insufficientHeadroom = err {
        return
      }
      fail("expected insufficientHeadroom, got \(err)")
    }
  }

  func testShutdownAllStopsEveryServer() async throws {
    let (router, created) = makeRouter()
    _ = try await router.routeAndBegin(desc("A", 10))
    _ = try await router.routeAndBegin(desc("B", 10))
    await router.requestDone(modelID: "A")
    await router.requestDone(modelID: "B")
    await router.shutdownAll()
    expect(created().allSatisfy(\.didStop)) == true
  }

  func testUnloadAllowsNextServerToLoad() async throws {
    let (router, created) = makeRouter()
    _ = try await router.routeAndBegin(desc("A", 10))
    await router.requestDone(modelID: "A")
    await router.unload(modelID: "A")
    _ = try await router.routeAndBegin(desc("B", 10))
    expect(created().count) == 2
    expect(created()[0].didStop) == true
    expect(created()[1].didStop) == false
  }

  func testRouterPublishesTypedLifecycleEvents() async throws {
    let events = RouterEventsBox()
    let (router, _) = makeRouter { event in
      events.append(event)
    }

    _ = try await router.routeAndBegin(desc("A", 10))
    await router.requestDone(modelID: "A")
    await router.unload(modelID: "A")

    expect(events.getAll()) == [
      .modelSpawned(modelID: "A", kind: .chat),
      .modelUnloaded(modelID: "A", kind: .chat),
    ]
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

    expect(created()[0].didStop) == true
    expect(events.getAll()) == [
      .modelSpawned(modelID: "A", kind: .chat),
      .modelSpawned(modelID: "B", kind: .chat),
      .modelEvicted(modelID: "A", kind: .chat),
      .modelSpawned(modelID: "C", kind: .chat),
    ]
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
    expect(snapshot.loaded.map(\.modelID)) == ["chat"]
    expect(events.getAll()) == [
      .modelSpawned(modelID: "embed", kind: .embedding),
      .modelEvicted(modelID: "embed", kind: .embedding),
      .modelSpawned(modelID: "chat", kind: .chat),
    ]
  }

  func testBrokerEventMapsRouterEvictionsToModelEvictedKind() {
    let modelEvent = BrokerEvent(routerEvent: .modelEvicted(modelID: "A", kind: .chat))
    expect(modelEvent.kind) == .modelEvicted
    expect(modelEvent.model) == "A"
    expect(modelEvent.message) == "evicted chat model=A"

    let embeddingEvent = BrokerEvent(
      routerEvent: .modelEvicted(modelID: "embed", kind: .embedding))
    expect(embeddingEvent.kind) == .modelEvicted
    expect(embeddingEvent.model) == "embed"
    expect(embeddingEvent.message) == "evicted embedding model=embed"
  }

  // MARK: - Preemption and priority

  private func makePreemptRouter(
    totalGB: Int64,
    preemptCooldownMillis: UInt64,
    events: RouterEventsBox? = nil
  ) -> (ModelRouter, FakesBox) {
    let memory = MemoryModel(totalGB: totalGB)
    let created = FakesBox()
    let spawner = makeRecordingSpawner(created: created, memory: memory)
    let sink: @Sendable (RouterLifecycleEvent) -> Void = { event in events?.append(event) }
    let router = ModelRouter(
      reserveBytes: 0,
      memoryProbe: memory.probe(),
      spawner: spawner,
      settleAttempts: 5,
      settleIntervalMillis: 1,
      preemptCooldownMillis: preemptCooldownMillis,
      requestWaitTimeoutMillis: 200,
      eventSink: sink
    )
    return (router, created)
  }

  func testHigherPriorityLoadForceEvictsBusyEmbeddingAfterDrainWindow() async throws {
    let events = RouterEventsBox()
    let (router, created) = makePreemptRouter(
      totalGB: 80, preemptCooldownMillis: 60_000, events: events)

    // The embedding stays busy: no embeddingRequestDone call releases it, so the
    // drain window elapses and the chat load force-evicts it.
    _ = try await router.routeEmbeddingAndBegin(embeddingDesc("embed", 40))
    _ = try await router.routeAndBegin(desc("chat", 50))

    let snap = await router.snapshot()
    expect(snap.loaded.map(\.modelID)) == ["chat"]
    expect(created.getAll()[0].didStop) == true
    expect(events.getAll()) == [
      .modelSpawned(modelID: "embed", kind: .embedding),
      .modelPreempted(modelID: "embed", kind: .embedding),
      .modelSpawned(modelID: "chat", kind: .chat),
    ]
  }

  func testPreemptionReclaimsBusyModelWhenRequestCompletesDuringDrain() async throws {
    let events = RouterEventsBox()
    let (router, _) = makePreemptRouter(
      totalGB: 80, preemptCooldownMillis: 60_000, events: events)

    let chatModel = desc("chat", 50)
    _ = try await router.routeEmbeddingAndBegin(embeddingDesc("embed", 40))
    async let chat = router.routeAndBegin(chatModel)
    // Let the chat load mark the embedding as draining, then complete the
    // embedding's in-flight request so it is reclaimed cleanly during the window.
    for _ in 0..<50 {
      await Task.yield()
    }
    await router.embeddingRequestDone(modelID: "embed")
    _ = try await chat

    let snap = await router.snapshot()
    expect(snap.loaded.map(\.modelID)) == ["chat"]
    expect(events.getAll()) == [
      .modelSpawned(modelID: "embed", kind: .embedding),
      .modelPreempted(modelID: "embed", kind: .embedding),
      .modelSpawned(modelID: "chat", kind: .chat),
    ]
  }

  func testReloadCooldownRefusesPreemptedModelWhileContended() async throws {
    let (router, _) = makePreemptRouter(totalGB: 80, preemptCooldownMillis: 60_000)

    _ = try await router.routeEmbeddingAndBegin(embeddingDesc("embed", 40))
    _ = try await router.routeAndBegin(desc("chat", 50))  // preempts the busy embedding

    // Chat (50 GB) is resident on 80 GB, so reloading embed (40 GB) still needs
    // room the higher-priority chat holds; the cooldown refuses it.
    var refusedWithYielding = false
    do {
      _ = try await router.routeEmbeddingAndBegin(embeddingDesc("embed", 40))
      fail("expected modelYielding during the reload cooldown")
    } catch let err as ModelRouter.RouteError {
      if case .modelYielding = err {
        refusedWithYielding = true
      } else {
        throw err
      }
    }
    expect(refusedWithYielding) == true
  }

  func testPinnedModelSurvivesHigherPriorityContention() async throws {
    let (router, created) = makePreemptRouter(totalGB: 80, preemptCooldownMillis: 60_000)

    _ = try await router.routeAndBegin(
      desc("pinned", 40), loadConfig: ModelLoadConfig(pinned: true))
    await router.requestDone(modelID: "pinned")  // idle, but pinned

    var refusedWithHeadroom = false
    do {
      _ = try await router.routeAndBegin(desc("B", 50))
      fail("expected insufficientHeadroom because the pinned model cannot be evicted")
    } catch let err as ModelRouter.RouteError {
      if case .insufficientHeadroom = err {
        refusedWithHeadroom = true
      } else {
        throw err
      }
    }
    expect(refusedWithHeadroom) == true
    expect(created.getAll()[0].didStop) == false
  }

  func testBrokerEventMapsRouterPreemptionToModelPreemptedKind() {
    let event = BrokerEvent(routerEvent: .modelPreempted(modelID: "embed", kind: .embedding))
    expect(event.kind) == .modelPreempted
    expect(event.model) == "embed"
    expect(event.message) == "preempted embedding model=embed"
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
    expect(routedServers[0] === routedServers[1]) == true
    let delayedSpawnCount = await delayedSpawner.spawnCount()
    expect(delayedSpawnCount) == 1

    let snapshot = await router.snapshot()
    expect(snapshot.loaded.count) == 1
    expect(snapshot.loaded.first?.inFlightRequests) == 2
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
      fail("expected first embedding load to fail")
    } catch let error as ModelRouter.RouteError {
      guard case .backendLaunchFailed = error else {
        fail("expected backendLaunchFailed, got \(error)")
        return
      }
    }

    let routedServer = try await router.routeEmbeddingAndBegin(model)
    expect(routedServer === embeddingServer) == true
    let retrySpawnCount = await retrySpawner.spawnCount()
    expect(retrySpawnCount) == 2
  }

  // MARK: - Admission queue

  private func makeQueueRouter(
    totalGB: Int64,
    requestWaitTimeoutMillis: UInt64
  ) -> ModelRouter {
    let memory = MemoryModel(totalGB: totalGB)
    let spawner = makeRecordingSpawner(memory: memory)
    return ModelRouter(
      reserveBytes: 0,
      memoryProbe: memory.probe(),
      spawner: spawner,
      settleAttempts: 5,
      settleIntervalMillis: 1,
      requestWaitTimeoutMillis: requestWaitTimeoutMillis
    )
  }

  func testContendedLoadParksUntilMemoryFrees() async throws {
    let router = makeQueueRouter(totalGB: 80, requestWaitTimeoutMillis: 5_000)
    // A busy chat model holds 50 GB and nothing lower-priority can be evicted.
    _ = try await router.routeAndBegin(desc("A", 50))
    let bModel = desc("B", 50)
    async let second: ModelServer = router.routeAndBegin(bModel)
    try await Task.sleep(nanoseconds: 30_000_000)
    var snap = await router.snapshot()
    expect(snap.loaded.map(\.modelID)) == ["A"]  // B is parked, not loaded

    await router.unload(modelID: "A")  // frees 50 GB and wakes the waiter
    _ = try await second
    snap = await router.snapshot()
    expect(snap.loaded.map(\.modelID)) == ["B"]
  }

  func testHigherPriorityWaiterAdmittedFirstWhenRoomFrees() async throws {
    let router = makeQueueRouter(totalGB: 80, requestWaitTimeoutMillis: 300)
    // A busy 40 GB chat model blocks both waiters until it is unloaded.
    _ = try await router.routeAndBegin(desc("hog", 40))
    let embedModel = embeddingDesc("embed", 50)
    let vipModel = desc("vip", 50)
    async let embedTask: ModelServer = router.routeEmbeddingAndBegin(embedModel)
    try await Task.sleep(nanoseconds: 30_000_000)
    async let vipTask: ModelServer = router.routeAndBegin(vipModel)
    try await Task.sleep(nanoseconds: 30_000_000)

    // Freed room fits only one 50 GB load; the high-priority chat wins it.
    await router.unload(modelID: "hog")
    _ = try await vipTask
    let snap = await router.snapshot()
    expect(snap.loaded.contains { $0.modelID == "vip" }) == true
    expect(snap.loaded.contains { $0.modelID == "embed" }) == false

    var embedTimedOut = false
    do {
      _ = try await embedTask
      fail("expected the lower-priority embed to time out")
    } catch let err as ModelRouter.RouteError {
      if case .insufficientHeadroom = err {
        embedTimedOut = true
      } else {
        throw err
      }
    }
    expect(embedTimedOut) == true
  }

  func testParkedLoadTimesOutWhenRoomNeverFrees() async throws {
    let router = makeQueueRouter(totalGB: 20, requestWaitTimeoutMillis: 100)
    var timedOut = false
    do {
      _ = try await router.routeAndBegin(desc("huge", 50))
      fail("expected insufficientHeadroom after the wait budget expired")
    } catch let err as ModelRouter.RouteError {
      if case .insufficientHeadroom = err {
        timedOut = true
      } else {
        throw err
      }
    }
    expect(timedOut) == true
  }

  func testAdmissionQueueFullKeepsHeadroomError() async throws {
    let router = makeQueueRouter(totalGB: 20, requestWaitTimeoutMillis: 5_000)
    let recorder = ParkedTaskOutcomeRecorder()
    var parkedTasks: [Task<Void, Never>] = []
    parkedTasks.reserveCapacity(256)
    for index in 0..<256 {
      let model = desc("huge-\(index)", 50)
      parkedTasks.append(
        Task {
          do {
            _ = try await router.routeAndBegin(model)
            await recorder.recordFailure("parked request \(index) unexpectedly completed")
          } catch let error as ModelRouter.RouteError {
            guard case .powerPaused = error else {
              await recorder.recordFailure(
                "expected parked request \(index) to fail with powerPaused, got \(error)"
              )
              return
            }
          } catch {
            await recorder.recordFailure("unexpected error \(error)")
          }
        })
    }
    try await Task.sleep(nanoseconds: 50_000_000)

    do {
      _ = try await router.routeAndBegin(desc("overflow", 50))
      fail("expected the overflow request to surface insufficientHeadroom immediately")
    } catch let error as ModelRouter.RouteError {
      guard case .insufficientHeadroom = error else {
        fail("expected insufficientHeadroom, got \(error)")
        return
      }
    }

    await router.applyPowerThrottle(.hard, haltReason: "low_power_mode")
    for task in parkedTasks {
      _ = await task.result
    }
    let failures = await recorder.messages()
    expect(failures.isEmpty) == true
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
    expect(snapshot.loaded.first?.inFlightRequests) == 1

    await router.requestDone(modelID: model.id)
    _ = try await second
    snapshot = await router.snapshot()
    expect(snapshot.loaded.first?.inFlightRequests) == 1
  }

  func testEmbeddingContentionAdmitsPastRouterLimit() async throws {
    let router = makeEmbeddingRouter(embeddingMaxConcurrency: 1)
    let model = embeddingDesc("embed", 10)
    let first = try await router.routeEmbeddingAndBegin(model)
    let second = try await router.routeEmbeddingAndBegin(model)

    expect(first === second) == true
    let snapshot = await router.snapshot()
    expect(snapshot.loaded.first?.inFlightRequests) == 2
  }

  func testChatQueueTimeoutSurfacesConcurrencyLimit() async throws {
    let router = makeChatRouter(chatMaxConcurrency: 1)
    await router.setQueueTimeoutNanos(50_000_000)
    let model = desc("A", 10)
    _ = try await router.routeAndBegin(model)  // never released

    let result = await Task { try await router.routeAndBegin(model) }.result
    switch result {
    case .failure(let error as ModelRouter.RouteError):
      guard case .concurrencyLimitExceeded = error else {
        fail("expected concurrencyLimitExceeded, got \(error)")
        return
      }
    case .failure(let error):
      fail("expected concurrencyLimitExceeded, got unexpected error \(error)")
    case .success:
      fail("expected concurrencyLimitExceeded after the queue wait timed out")
    }
  }

  func testEmbeddingQueueTimeoutDoesNotRejectAtRouterLimit() async throws {
    let router = makeEmbeddingRouter(embeddingMaxConcurrency: 1)
    await router.setQueueTimeoutNanos(50_000_000)
    let model = embeddingDesc("embed", 10)
    _ = try await router.routeEmbeddingAndBegin(model)
    _ = try await router.routeEmbeddingAndBegin(model)

    let snapshot = await router.snapshot()
    expect(snapshot.loaded.first?.inFlightRequests) == 2
  }

  func testChatDefaultWidthAdmitsUpToLimitThenQueues() async throws {
    let router = makeChatRouter(chatMaxConcurrency: 4)
    await router.setQueueTimeoutNanos(50_000_000)
    let model = desc("A", 10)
    for _ in 0..<4 {
      _ = try await router.routeAndBegin(model)  // four admitted without waiting
    }
    let snapshot = await router.snapshot()
    expect(snapshot.loaded.first?.inFlightRequests) == 4

    let result = await Task { try await router.routeAndBegin(model) }.result
    switch result {
    case .failure(let error as ModelRouter.RouteError):
      guard case .concurrencyLimitExceeded = error else {
        fail("expected concurrencyLimitExceeded, got \(error)")
        return
      }
    case .failure(let error):
      fail("expected concurrencyLimitExceeded, got unexpected error \(error)")
    case .success:
      fail("expected the fifth request to queue and time out")
    }
  }

  func testUnloadDrainsQueuedWaiter() async throws {
    let router = makeChatRouter(chatMaxConcurrency: 1)
    let model = desc("A", 10)
    _ = try await router.routeAndBegin(model)
    let second = Task { try await router.routeAndBegin(model) }
    try await Task.sleep(nanoseconds: 50_000_000)  // let the second request queue
    await router.unload(modelID: model.id)

    let result = await second.result
    switch result {
    case .failure(let error as ModelRouter.RouteError):
      guard case .queueDrained(let drainedModelID) = error else {
        fail("expected queueDrained, got \(error)")
        return
      }
      expect(drainedModelID) == model.id
    case .failure(let error):
      fail("expected queueDrained, got unexpected error \(error)")
    case .success:
      fail("expected the drained waiter to surface an error rather than hang")
    }
  }

  func testHardCancelsQueuedConcurrencyWaiterAsPowerPaused() async throws {
    let router = makeChatRouter(chatMaxConcurrency: 1)
    let model = desc("A", 10)
    _ = try await router.routeAndBegin(model)
    let second = Task { try await router.routeAndBegin(model) }
    try await Task.sleep(nanoseconds: 50_000_000)
    await router.applyPowerThrottle(.hard, haltReason: "low_power_mode")

    let result = await second.result
    switch result {
    case .failure(let error as ModelRouter.RouteError):
      guard case .powerPaused(let reason) = error else {
        fail("expected powerPaused, got \(error)")
        return
      }
      expect(reason) == "low_power_mode"
    case .failure(let error):
      fail("expected powerPaused, got unexpected error \(error)")
    case .success:
      fail("expected queued waiter to fail with powerPaused")
    }
  }

  func testHardCancelsQueuedAdmissionWaiterAsPowerPaused() async throws {
    let router = makeQueueRouter(totalGB: 80, requestWaitTimeoutMillis: 5_000)
    _ = try await router.routeAndBegin(desc("A", 50))
    let waitingModel = desc("B", 50)
    let second = Task { try await router.routeAndBegin(waitingModel) }
    try await Task.sleep(nanoseconds: 30_000_000)
    await router.applyPowerThrottle(.hard, haltReason: "low_power_mode")

    let result = await second.result
    switch result {
    case .failure(let error as ModelRouter.RouteError):
      guard case .powerPaused(let reason) = error else {
        fail("expected powerPaused, got \(error)")
        return
      }
      expect(reason) == "low_power_mode"
    case .failure(let error):
      fail("expected powerPaused, got unexpected error \(error)")
    case .success:
      fail("expected queued admission waiter to fail with powerPaused")
    }
  }

  func testChatWaitersWakeInFifoOrder() async throws {
    let router = makeChatRouter(chatMaxConcurrency: 1)
    let model = desc("A", 10)
    _ = try await router.routeAndBegin(model)  // holds the only slot

    let order = OrderRecorder()
    let w0 = Task {
      try await acquireThenRecord(router: router, model: model, index: 0, order: order)
    }
    try await Task.sleep(nanoseconds: 20_000_000)
    let w1 = Task {
      try await acquireThenRecord(router: router, model: model, index: 1, order: order)
    }
    try await Task.sleep(nanoseconds: 20_000_000)
    let w2 = Task {
      try await acquireThenRecord(router: router, model: model, index: 2, order: order)
    }
    try await Task.sleep(nanoseconds: 20_000_000)

    for _ in 0..<3 {
      await router.requestDone(modelID: model.id)
      try await Task.sleep(nanoseconds: 20_000_000)
    }
    let w0Result = await w0.result
    let w1Result = await w1.result
    let w2Result = await w2.result
    for result in [w0Result, w1Result, w2Result] {
      guard case .success = result else {
        if case .failure(let error) = result {
          fail("expected queued waiter to acquire a slot, got \(error)")
        } else {
          fail("expected queued waiter to acquire a slot")
        }
        return
      }
    }
    let recorded = await order.values()
    expect(recorded) == [0, 1, 2]
  }
}

private actor OrderRecorder {
  private var recorded: [Int] = []
  func append(_ value: Int) { recorded.append(value) }
  func values() -> [Int] { recorded }
}

// MARK: - ParkedTaskOutcomeRecorder

private actor ParkedTaskOutcomeRecorder {
  private var failures: [String] = []

  func recordFailure(_ message: String) { failures.append(message) }
  func messages() -> [String] { failures }
}

/// Acquire a chat slot then record `index`. A free function so `async let` does
/// not send the non-Sendable test case across a concurrency boundary.
private func acquireThenRecord(
  router: ModelRouter,
  model: ModelDescriptor,
  index: Int,
  order: OrderRecorder
) async throws {
  _ = try await router.routeAndBegin(model)
  await order.append(index)
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
