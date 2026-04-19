//
//  ModelRouter.swift
//  SwiftLMRuntime
//
//  Created by Alex Goodkind <alex@goodkind.io> on 2026-04-18.
//  Copyright © 2026
//

import AppLogger
import Foundation
import SwiftLMBackend
import SwiftLMCore

private let log = AppLogger.logger(category: "ModelRouter")

// MARK: - Backend abstraction

/// The minimum interface ``ModelRouter`` needs from a SwiftLM supervisor.
public protocol SwiftLMBackendProtocol: AnyObject, Sendable {
  var modelID: String { get }
  var port: Int { get }
  var sizeBytes: Int64 { get }
  func launch() throws
  func shutdown()
}

// MARK: - Spawner

public typealias BackendSpawner = @Sendable (_ model: ModelDescriptor, _ port: Int) throws -> SwiftLMBackendProtocol

public typealias EmbeddingSpawner = @Sendable (_ model: ModelDescriptor) async throws -> EmbeddingBackendProtocol

// MARK: - Router state

private final class LoadedEntry: @unchecked Sendable {
  let backend: SwiftLMBackendProtocol
  var lastUsed: Date
  var inFlight: Int
  init(backend: SwiftLMBackendProtocol) {
    self.backend = backend
    self.lastUsed = Date()
    self.inFlight = 0
  }
}

private final class EmbeddingLoadedEntry: @unchecked Sendable {
  let backend: EmbeddingBackendProtocol
  var lastUsed: Date
  var inFlight: Int
  init(backend: EmbeddingBackendProtocol) {
    self.backend = backend
    self.lastUsed = Date()
    self.inFlight = 0
  }
}

// MARK: - ModelRouter

/// Tracks loaded SwiftLM backends and embedding backends.
public actor ModelRouter {
  public let budget: MemoryBudget
  public let portRange: ClosedRange<Int>
  public let spawner: BackendSpawner
  public let embeddingSpawner: EmbeddingSpawner?

  public let logSink: @Sendable (String) -> Void

  private var loaded: [String: LoadedEntry] = [:]
  private var embeddingLoaded: [String: EmbeddingLoadedEntry] = [:]
  private var allocatedPorts: Set<Int> = []

  public init(
    budget: MemoryBudget,
    portRange: ClosedRange<Int> = 5500...5599,
    spawner: @escaping BackendSpawner,
    embeddingSpawner: EmbeddingSpawner? = nil,
    log: @escaping @Sendable (String) -> Void = { _ in }
  ) {
    self.budget = budget
    self.portRange = portRange
    self.spawner = spawner
    self.embeddingSpawner = embeddingSpawner
    self.logSink = log
  }

  // MARK: - Snapshot

  public struct Snapshot: Sendable {
    public let loaded: [EvictionCandidate]
    public let allocatedBytes: Int64
  }

  public func snapshot() -> Snapshot {
    var total: Int64 = 0
    var cands: [EvictionCandidate] = []
    for entry in loaded.values {
      total += entry.backend.sizeBytes
      cands.append(
        EvictionCandidate(
          modelID: entry.backend.modelID,
          sizeBytes: entry.backend.sizeBytes,
          lastUsed: entry.lastUsed,
          inFlightRequests: entry.inFlight,
          isEmbedding: false
        ))
    }
    for entry in embeddingLoaded.values {
      total += entry.backend.sizeBytes
      cands.append(
        EvictionCandidate(
          modelID: entry.backend.modelID,
          sizeBytes: entry.backend.sizeBytes,
          lastUsed: entry.lastUsed,
          inFlightRequests: entry.inFlight,
          isEmbedding: true
        ))
    }
    return Snapshot(loaded: cands, allocatedBytes: total)
  }

  // MARK: - Routing chat

  public enum RouteError: Error, Equatable {
    case noFreePort
    case cannotFitInBudget(modelID: String, sizeBytes: Int64)
    case backendLaunchFailed(modelID: String)
    case wrongKindForChat(modelID: String)
    case wrongKindForEmbedding(modelID: String)
    case embeddingSpawnerMissing
  }

  public func routeAndBegin(_ model: ModelDescriptor) throws -> SwiftLMBackendProtocol {
    guard model.kind != .embedding else {
      throw RouteError.wrongKindForChat(modelID: model.id)
    }
    if let entry = loaded[model.id] {
      entry.lastUsed = Date()
      entry.inFlight += 1
      return entry.backend
    }

    let snap = snapshot()
    if !budget.canAccommodate(currentlyAllocated: snap.allocatedBytes, needing: model.sizeBytes) {
      let plan = EvictionPolicy.planEviction(
        candidates: snap.loaded,
        needing: model.sizeBytes,
        budget: budget,
        currentlyAllocated: snap.allocatedBytes
      )
      if plan.isEmpty {
        throw RouteError.cannotFitInBudget(modelID: model.id, sizeBytes: model.sizeBytes)
      }
      for id in plan { unload(modelID: id) }
    }

    guard let port = firstFreePort() else {
      throw RouteError.noFreePort
    }
    allocatedPorts.insert(port)

    let backend: SwiftLMBackendProtocol
    do {
      backend = try spawner(model, port)
      try backend.launch()
    } catch {
      allocatedPorts.remove(port)
      log.error("router.backend_launch_failed model=\(model.id, privacy: .public) err=\(String(describing: error), privacy: .public)")
      logSink("backend launch failed model=\(model.id) err=\(error)")
      throw RouteError.backendLaunchFailed(modelID: model.id)
    }

    let entry = LoadedEntry(backend: backend)
    entry.inFlight = 1
    loaded[model.id] = entry
    log.notice("router.model_spawned model=\(model.id, privacy: .public) port=\(port, privacy: .public)")
    logSink("spawned model=\(model.id) port=\(port)")
    return backend
  }

  // MARK: - Routing embeddings

  public func routeEmbeddingAndBegin(_ model: ModelDescriptor) async throws -> EmbeddingBackendProtocol {
    guard model.kind == .embedding else {
      throw RouteError.wrongKindForEmbedding(modelID: model.id)
    }
    guard let embeddingSpawner else {
      throw RouteError.embeddingSpawnerMissing
    }

    if let entry = embeddingLoaded[model.id] {
      entry.lastUsed = Date()
      entry.inFlight += 1
      return entry.backend
    }

    let snap = snapshot()
    if !budget.canAccommodate(currentlyAllocated: snap.allocatedBytes, needing: model.sizeBytes) {
      let plan = EvictionPolicy.planEviction(
        candidates: snap.loaded,
        needing: model.sizeBytes,
        budget: budget,
        currentlyAllocated: snap.allocatedBytes
      )
      if plan.isEmpty {
        throw RouteError.cannotFitInBudget(modelID: model.id, sizeBytes: model.sizeBytes)
      }
      for id in plan { unload(modelID: id) }
    }

    let backend: EmbeddingBackendProtocol
    do {
      backend = try await embeddingSpawner(model)
    } catch {
      log.error("router.embedding_launch_failed model=\(model.id, privacy: .public) err=\(String(describing: error), privacy: .public)")
      logSink("embedding launch failed model=\(model.id) err=\(error)")
      throw RouteError.backendLaunchFailed(modelID: model.id)
    }

    let entry = EmbeddingLoadedEntry(backend: backend)
    entry.inFlight = 1
    embeddingLoaded[model.id] = entry
    log.notice("router.embedding_spawned model=\(model.id, privacy: .public)")
    logSink("spawned embedding model=\(model.id)")
    return backend
  }

  public func requestDone(modelID: String) {
    guard let entry = loaded[modelID] else {
      log.fault("router.request_done_unknown_chat_model model=\(modelID, privacy: .public)")
      return
    }
    if entry.inFlight > 0 { entry.inFlight -= 1 }
    entry.lastUsed = Date()
    log.debug("router.request_done model=\(modelID, privacy: .public) in_flight=\(entry.inFlight, privacy: .public)")
  }

  public func embeddingRequestDone(modelID: String) {
    guard let entry = embeddingLoaded[modelID] else {
      log.fault("router.request_done_unknown_embedding_model model=\(modelID, privacy: .public)")
      return
    }
    if entry.inFlight > 0 { entry.inFlight -= 1 }
    entry.lastUsed = Date()
    log.debug("router.embedding_request_done model=\(modelID, privacy: .public) in_flight=\(entry.inFlight, privacy: .public)")
  }

  public func unload(modelID: String) {
    if let entry = loaded.removeValue(forKey: modelID) {
      let port = entry.backend.port
      allocatedPorts.remove(port)
      entry.backend.shutdown()
      log.notice("router.model_unloaded model=\(modelID, privacy: .public) port=\(port, privacy: .public)")
      logSink("unloaded model=\(modelID) port=\(port)")
      return
    }
    if let entry = embeddingLoaded.removeValue(forKey: modelID) {
      entry.backend.shutdown()
      log.notice("router.embedding_unloaded model=\(modelID, privacy: .public)")
      logSink("unloaded embedding model=\(modelID)")
      return
    }
  }

  public func shutdownAll() {
    let snap = snapshot()
    log.notice("router.shutdown_all count=\(snap.loaded.count, privacy: .public)")
    for c in snap.loaded {
      unload(modelID: c.modelID)
    }
  }

  private func firstFreePort() -> Int? {
    for p in portRange where !allocatedPorts.contains(p) {
      return p
    }
    return nil
  }
}
