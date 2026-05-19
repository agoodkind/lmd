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
import SwiftLMTrace

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

private struct LoadedEntry: Sendable {
  let backend: SwiftLMBackendProtocol
  let loadID: UUID
  let backendObjectID: String
  var lastUsed: Date
  var inFlight: Int
  init(backend: SwiftLMBackendProtocol) {
    self.backend = backend
    self.loadID = UUID()
    self.backendObjectID = TraceContext.backendObjectID(of: backend)
    self.lastUsed = Date()
    self.inFlight = 0
  }
}

private struct EmbeddingLoadedEntry: Sendable {
  let backend: EmbeddingBackendProtocol
  let loadID: UUID
  let backendObjectID: String
  var lastUsed: Date
  var inFlight: Int
  init(backend: EmbeddingBackendProtocol, loadID: UUID) {
    self.backend = backend
    self.loadID = loadID
    self.backendObjectID = TraceContext.backendObjectID(of: backend)
    self.lastUsed = Date()
    self.inFlight = 0
  }
}

private final class EmbeddingLoadingEntry: Sendable {
  let id: UUID
  let task: Task<EmbeddingBackendProtocol, Error>

  init(task: Task<EmbeddingBackendProtocol, Error>) {
    self.id = UUID()
    self.task = task
  }
}

private enum EmbeddingRouteState: Sendable {
  case loading(EmbeddingLoadingEntry)
  case loaded(EmbeddingLoadedEntry)
}

private enum UnloadDisposition {
  case unloaded
  case evicted
}

public enum RouterLifecycleEvent: Sendable, Equatable {
  case modelSpawned(modelID: String, port: Int)
  case modelUnloaded(modelID: String, port: Int)
  case modelEvicted(modelID: String, port: Int)
  case embeddingSpawned(modelID: String)
  case embeddingUnloaded(modelID: String)
  case embeddingEvicted(modelID: String)
  case embeddingLoadCancelled(modelID: String, loadID: String)
  case backendLaunchFailed(modelID: String, errorDescription: String)
  case embeddingBackendUnsupported(modelID: String, reason: String)
  case embeddingLaunchFailed(modelID: String, errorDescription: String)
}

// MARK: - ModelRouter

/// Tracks loaded SwiftLM backends and embedding backends.
public actor ModelRouter {
  public let budget: MemoryBudget
  public let portRange: ClosedRange<Int>
  public let spawner: BackendSpawner
  public let embeddingSpawner: EmbeddingSpawner?

  public let eventSink: @Sendable (RouterLifecycleEvent) -> Void

  private var loaded: [String: LoadedEntry] = [:]
  private var embeddingRoutes: [String: EmbeddingRouteState] = [:]
  private var allocatedPorts: Set<Int> = []

  public init(
    budget: MemoryBudget,
    portRange: ClosedRange<Int> = 5500...5599,
    spawner: @escaping BackendSpawner,
    embeddingSpawner: EmbeddingSpawner? = nil,
    eventSink: @escaping @Sendable (RouterLifecycleEvent) -> Void = { _ in }
  ) {
    self.budget = budget
    self.portRange = portRange
    self.spawner = spawner
    self.embeddingSpawner = embeddingSpawner
    self.eventSink = eventSink
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
    for state in embeddingRoutes.values {
      guard case .loaded(let entry) = state else {
        continue
      }
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

  // MARK: - Trace identity

  /// Identity record for a single loaded backend (chat or embedding). Used by
  /// the broker layer to attach `load_id` and `backend_obj` fields to its
  /// per-request trace lines, and by the background sampler to enumerate
  /// currently resident backends.
  public struct LoadedModelInfo: Sendable {
    public let modelID: String
    public let kind: BackendKind
    public let loadID: UUID
    public let backendObjectID: String

    public init(modelID: String, kind: BackendKind, loadID: UUID, backendObjectID: String) {
      self.modelID = modelID
      self.kind = kind
      self.loadID = loadID
      self.backendObjectID = backendObjectID
    }
  }

  /// Return `(loadID, backendObjectID)` for a loaded chat backend, or `nil`.
  public func chatLoadInfo(modelID: String) -> (loadID: UUID, backendObjectID: String)? {
    guard let entry = loaded[modelID] else {
      return nil
    }
    return (entry.loadID, entry.backendObjectID)
  }

  /// Return `(loadID, backendObjectID)` for a loaded embedding backend, or `nil`.
  ///
  /// Returns `nil` for an embedding still in the `.loading` state because no
  /// backend instance exists yet to identify.
  public func embeddingLoadInfo(modelID: String) -> (loadID: UUID, backendObjectID: String)? {
    guard let state = embeddingRoutes[modelID], case .loaded(let entry) = state else {
      return nil
    }
    return (entry.loadID, entry.backendObjectID)
  }

  /// Enumerate every currently resident backend.
  public func loadedModelInfos() -> [LoadedModelInfo] {
    var infos: [LoadedModelInfo] = []
    for entry in loaded.values {
      infos.append(
        LoadedModelInfo(
          modelID: entry.backend.modelID,
          kind: .chat,
          loadID: entry.loadID,
          backendObjectID: entry.backendObjectID
        ))
    }
    for state in embeddingRoutes.values {
      guard case .loaded(let entry) = state else {
        continue
      }
      infos.append(
        LoadedModelInfo(
          modelID: entry.backend.modelID,
          kind: .embedding,
          loadID: entry.loadID,
          backendObjectID: entry.backendObjectID
        ))
    }
    return infos
  }

  // MARK: - Routing chat

  public enum RouteError: Error, Equatable {
    case noFreePort
    case cannotFitInBudget(modelID: String, sizeBytes: Int64)
    case backendLaunchFailed(modelID: String)
    case wrongKindForChat(modelID: String)
    case wrongKindForEmbedding(modelID: String)
    case embeddingSpawnerMissing
    case unsupportedEmbeddingBackend(modelID: String, reason: String)
  }

  public func routeAndBegin(_ model: ModelDescriptor) throws -> SwiftLMBackendProtocol {
    BackendTrace.notice(
      phase: TracePhase.Router.routeBegin.rawValue,
      context: TraceContext(modelID: model.id, modelKind: .chat),
      snapshot: .current()
    )
    var resultLoadID: UUID? = nil
    var resultBackendObj: String? = nil
    defer {
      BackendTrace.notice(
        phase: TracePhase.Router.routeEnd.rawValue,
        context: TraceContext(
          modelID: model.id,
          modelKind: .chat,
          loadID: resultLoadID,
          backendObjectID: resultBackendObj
        ),
        snapshot: .current()
      )
    }
    guard model.kind != .embedding else {
      throw RouteError.wrongKindForChat(modelID: model.id)
    }
    if var entry = loaded[model.id] {
      entry.lastUsed = Date()
      entry.inFlight += 1
      loaded[model.id] = entry
      resultLoadID = entry.loadID
      resultBackendObj = entry.backendObjectID
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
      for id in plan { evict(modelID: id) }
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
      let errorDescription = String(describing: error)
      log.error("router.backend_launch_failed model=\(model.id, privacy: .public) err=\(errorDescription, privacy: .public)")
      eventSink(.backendLaunchFailed(modelID: model.id, errorDescription: errorDescription))
      throw RouteError.backendLaunchFailed(modelID: model.id)
    }

    var entry = LoadedEntry(backend: backend)
    entry.inFlight = 1
    loaded[model.id] = entry
    resultLoadID = entry.loadID
    resultBackendObj = entry.backendObjectID
    log.notice("router.model_spawned model=\(model.id, privacy: .public) port=\(port, privacy: .public)")
    BackendTrace.notice(
      phase: TracePhase.Router.modelSpawned.rawValue,
      context: TraceContext(
        modelID: model.id,
        modelKind: .chat,
        loadID: entry.loadID,
        backendObjectID: entry.backendObjectID
      ),
      snapshot: .current(),
      extras: ["port": "\(port)"]
    )
    eventSink(.modelSpawned(modelID: model.id, port: port))
    return backend
  }

  // MARK: - Routing embeddings

  public func routeEmbeddingAndBegin(_ model: ModelDescriptor) async throws -> EmbeddingBackendProtocol {
    BackendTrace.notice(
      phase: TracePhase.Router.routeBegin.rawValue,
      context: TraceContext(modelID: model.id, modelKind: .embedding),
      snapshot: .current()
    )
    var resultLoadID: UUID? = nil
    var resultBackendObj: String? = nil
    defer {
      BackendTrace.notice(
        phase: TracePhase.Router.routeEnd.rawValue,
        context: TraceContext(
          modelID: model.id,
          modelKind: .embedding,
          loadID: resultLoadID,
          backendObjectID: resultBackendObj
        ),
        snapshot: .current()
      )
    }
    guard model.kind == .embedding else {
      throw RouteError.wrongKindForEmbedding(modelID: model.id)
    }
    guard let embeddingSpawner else {
      throw RouteError.embeddingSpawnerMissing
    }

    if let state = embeddingRoutes[model.id] {
      switch state {
      case .loaded(var entry):
        entry.lastUsed = Date()
        entry.inFlight += 1
        embeddingRoutes[model.id] = .loaded(entry)
        resultLoadID = entry.loadID
        resultBackendObj = entry.backendObjectID
        return entry.backend
      case .loading(let loading):
        log.debug("router.embedding_load_wait model=\(model.id, privacy: .public) load_id=\(loading.id.uuidString, privacy: .public)")
        let backend = try await finishEmbeddingLoad(model: model, loading: loading)
        if let info = embeddingLoadInfo(modelID: model.id) {
          resultLoadID = info.loadID
          resultBackendObj = info.backendObjectID
        }
        return backend
      }
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
      for id in plan { evict(modelID: id) }
    }

    let loadTask = Task {
      try await embeddingSpawner(model)
    }
    let loading = EmbeddingLoadingEntry(task: loadTask)
    embeddingRoutes[model.id] = .loading(loading)
    let backend = try await finishEmbeddingLoad(model: model, loading: loading)
    if let info = embeddingLoadInfo(modelID: model.id) {
      resultLoadID = info.loadID
      resultBackendObj = info.backendObjectID
    }
    return backend
  }

  public func requestDone(modelID: String) {
    guard var entry = loaded[modelID] else {
      log.fault("router.request_done_unknown_chat_model model=\(modelID, privacy: .public)")
      return
    }
    if entry.inFlight > 0 { entry.inFlight -= 1 }
    entry.lastUsed = Date()
    loaded[modelID] = entry
    log.debug("router.request_done model=\(modelID, privacy: .public) in_flight=\(entry.inFlight, privacy: .public)")
    BackendTrace.debug(
      phase: TracePhase.Router.requestDone.rawValue,
      context: TraceContext(
        modelID: modelID,
        modelKind: .chat,
        loadID: entry.loadID,
        backendObjectID: entry.backendObjectID
      ),
      snapshot: .current(),
      extras: ["inflight": "\(entry.inFlight)"]
    )
  }

  public func embeddingRequestDone(modelID: String) {
    guard let state = embeddingRoutes[modelID] else {
      log.fault("router.request_done_unknown_embedding_model model=\(modelID, privacy: .public)")
      return
    }

    guard case .loaded(var entry) = state else {
      log.fault("router.request_done_unknown_embedding_model model=\(modelID, privacy: .public)")
      return
    }

    if entry.inFlight > 0 { entry.inFlight -= 1 }
    entry.lastUsed = Date()
    embeddingRoutes[modelID] = .loaded(entry)
    log.debug("router.embedding_request_done model=\(modelID, privacy: .public) in_flight=\(entry.inFlight, privacy: .public)")
    BackendTrace.debug(
      phase: TracePhase.Router.embeddingRequestDone.rawValue,
      context: TraceContext(
        modelID: modelID,
        modelKind: .embedding,
        loadID: entry.loadID,
        backendObjectID: entry.backendObjectID
      ),
      snapshot: .current(),
      extras: ["inflight": "\(entry.inFlight)"]
    )
  }

  public func unload(modelID: String) {
    unload(modelID: modelID, disposition: .unloaded)
  }

  private func evict(modelID: String) {
    unload(modelID: modelID, disposition: .evicted)
  }

  private func unload(modelID: String, disposition: UnloadDisposition) {
    if let entry = loaded.removeValue(forKey: modelID) {
      let port = entry.backend.port
      allocatedPorts.remove(port)
      entry.backend.shutdown()
      let traceCtx = TraceContext(
        modelID: modelID,
        modelKind: .chat,
        loadID: entry.loadID,
        backendObjectID: entry.backendObjectID
      )
      switch disposition {
      case .unloaded:
        log.notice("router.model_unloaded model=\(modelID, privacy: .public) port=\(port, privacy: .public)")
        BackendTrace.notice(
          phase: TracePhase.Router.modelUnloaded.rawValue,
          context: traceCtx,
          snapshot: .current(),
          extras: ["port": "\(port)", "reason": "unloaded"]
        )
        eventSink(.modelUnloaded(modelID: modelID, port: port))
      case .evicted:
        log.notice("router.model_evicted model=\(modelID, privacy: .public) port=\(port, privacy: .public)")
        BackendTrace.notice(
          phase: TracePhase.Router.modelEvicted.rawValue,
          context: traceCtx,
          snapshot: .current(),
          extras: ["port": "\(port)", "reason": "evicted"]
        )
        eventSink(.modelEvicted(modelID: modelID, port: port))
      }
      return
    }
    if let state = embeddingRoutes.removeValue(forKey: modelID) {
      switch state {
      case .loaded(let entry):
        entry.backend.shutdown()
        let traceCtx = TraceContext(
          modelID: modelID,
          modelKind: .embedding,
          loadID: entry.loadID,
          backendObjectID: entry.backendObjectID
        )
        switch disposition {
        case .unloaded:
          log.notice("router.embedding_unloaded model=\(modelID, privacy: .public)")
          BackendTrace.notice(
            phase: TracePhase.Router.embeddingUnloaded.rawValue,
            context: traceCtx,
            snapshot: .current(),
            extras: ["reason": "unloaded"]
          )
          eventSink(.embeddingUnloaded(modelID: modelID))
        case .evicted:
          log.notice("router.embedding_evicted model=\(modelID, privacy: .public)")
          BackendTrace.notice(
            phase: TracePhase.Router.embeddingEvicted.rawValue,
            context: traceCtx,
            snapshot: .current(),
            extras: ["reason": "evicted"]
          )
          eventSink(.embeddingEvicted(modelID: modelID))
        }
      case .loading(let loading):
        loading.task.cancel()
        log.notice("router.embedding_load_cancelled model=\(modelID, privacy: .public) load_id=\(loading.id.uuidString, privacy: .public)")
        eventSink(.embeddingLoadCancelled(modelID: modelID, loadID: loading.id.uuidString))
      }
      return
    }
  }

  public func shutdownAll() {
    let snap = snapshot()
    let modelIDs = Set(snap.loaded.map(\.modelID)).union(embeddingRoutes.keys)
    log.notice("router.shutdown_all count=\(modelIDs.count, privacy: .public)")
    for modelID in modelIDs {
      unload(modelID: modelID)
    }
  }

  private func finishEmbeddingLoad(
    model: ModelDescriptor,
    loading: EmbeddingLoadingEntry
  ) async throws -> EmbeddingBackendProtocol {
    let backend: EmbeddingBackendProtocol
    do {
      backend = try await loading.task.value
    } catch let error as UnsupportedEmbeddingBackendError {
      let reason = error.description
      if clearEmbeddingLoadingIfCurrent(modelID: model.id, loading: loading) {
        log.error("router.embedding_backend_unsupported model=\(model.id, privacy: .public) load_id=\(loading.id.uuidString, privacy: .public) err=\(reason, privacy: .public)")
        eventSink(.embeddingBackendUnsupported(modelID: model.id, reason: reason))
      }
      throw RouteError.unsupportedEmbeddingBackend(modelID: model.id, reason: reason)
    } catch {
      let errorDescription = String(describing: error)
      if clearEmbeddingLoadingIfCurrent(modelID: model.id, loading: loading) {
        log.error("router.embedding_launch_failed model=\(model.id, privacy: .public) load_id=\(loading.id.uuidString, privacy: .public) err=\(errorDescription, privacy: .public)")
        eventSink(.embeddingLaunchFailed(modelID: model.id, errorDescription: errorDescription))
      }
      throw RouteError.backendLaunchFailed(modelID: model.id)
    }

    guard let state = embeddingRoutes[model.id] else {
      backend.shutdown()
      log.notice("router.embedding_load_discarded model=\(model.id, privacy: .public) load_id=\(loading.id.uuidString, privacy: .public) reason=unloaded")
      throw RouteError.backendLaunchFailed(modelID: model.id)
    }

    switch state {
    case .loaded(var entry):
      entry.lastUsed = Date()
      entry.inFlight += 1
      embeddingRoutes[model.id] = .loaded(entry)
      return entry.backend
    case .loading(let current) where current.id == loading.id:
      var entry = EmbeddingLoadedEntry(backend: backend, loadID: loading.id)
      entry.inFlight = 1
      embeddingRoutes[model.id] = .loaded(entry)
      log.notice("router.embedding_spawned model=\(model.id, privacy: .public) load_id=\(loading.id.uuidString, privacy: .public)")
      BackendTrace.notice(
        phase: TracePhase.Router.embeddingSpawned.rawValue,
        context: TraceContext(
          modelID: model.id,
          modelKind: .embedding,
          loadID: entry.loadID,
          backendObjectID: entry.backendObjectID
        ),
        snapshot: .current()
      )
      eventSink(.embeddingSpawned(modelID: model.id))
      return backend
    case .loading:
      backend.shutdown()
      log.fault("router.embedding_load_stale model=\(model.id, privacy: .public) load_id=\(loading.id.uuidString, privacy: .public)")
      throw RouteError.backendLaunchFailed(modelID: model.id)
    }
  }

  private func clearEmbeddingLoadingIfCurrent(
    modelID: String,
    loading: EmbeddingLoadingEntry
  ) -> Bool {
    guard let state = embeddingRoutes[modelID], case .loading(let current) = state,
          current.id == loading.id
    else {
      return false
    }
    embeddingRoutes.removeValue(forKey: modelID)
    return true
  }

  private func firstFreePort() -> Int? {
    for p in portRange where !allocatedPorts.contains(p) {
      return p
    }
    return nil
  }
}
