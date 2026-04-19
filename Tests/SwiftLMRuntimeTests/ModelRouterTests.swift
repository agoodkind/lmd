//
//  ModelRouterTests.swift
//  SwiftLMRuntimeTests
//
//  Created by Alex Goodkind <alex@goodkind.io> on 2026-04-18.
//  Copyright © 2026
//

import XCTest
@testable import SwiftLMCore
@testable import SwiftLMRuntime

/// Minimal fake backend that records lifecycle calls without spawning a process.
private final class FakeBackend: SwiftLMBackendProtocol, @unchecked Sendable {
  let modelID: String
  let port: Int
  let sizeBytes: Int64
  var launched = false
  var stopped = false

  init(modelID: String, port: Int, sizeBytes: Int64) {
    self.modelID = modelID
    self.port = port
    self.sizeBytes = sizeBytes
  }

  func launch() throws { launched = true }
  func shutdown() { stopped = true }
}

final class ModelRouterTests: XCTestCase {
  private let gb: Int64 = 1_073_741_824

  private func makeRouter(ceiling: Int64 = 80, reserve: Int64 = 0) -> (ModelRouter, () -> [FakeBackend]) {
    let created = FakesBox()
    let spawner: BackendSpawner = { model, port in
      let fake = FakeBackend(modelID: model.id, port: port, sizeBytes: model.sizeBytes)
      created.append(fake)
      return fake
    }
    let budget = MemoryBudget(
      ceilingBytes: ceiling * 1_073_741_824,
      reservedBytes: reserve * 1_073_741_824
    )
    let router = ModelRouter(budget: budget, portRange: 5500...5502, spawner: spawner)
    return (router, created.getAll)
  }

  /// Helper to descriptor from a name and size in GB.
  private func desc(_ name: String, _ sizeGB: Int64) -> ModelDescriptor {
    ModelDescriptor(id: name, displayName: name, path: "/tmp/\(name)", sizeBytes: sizeGB * gb)
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
}

/// Small thread-safe list wrapper used to observe spawner output from outside.
private final class FakesBox: @unchecked Sendable {
  private var items: [FakeBackend] = []
  private let lock = NSLock()
  func append(_ item: FakeBackend) { lock.lock(); items.append(item); lock.unlock() }
  func getAll() -> [FakeBackend] { lock.lock(); defer { lock.unlock() }; return items }
}
