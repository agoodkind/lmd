//
//  ModelRouter.swift
//  SwiftLMRuntime
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-04-18.
//  Copyright © 2026, all rights reserved.
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
  var isRunning: Bool { get }
  func launch() throws
  func shutdown()
}

// MARK: - Spawner

public typealias BackendSpawner =
  @Sendable (_ model: ModelDescriptor, _ port: Int, _ loadConfig: ModelLoadConfig) throws
  -> SwiftLMBackendProtocol

public typealias EmbeddingSpawner =
  @Sendable (_ model: ModelDescriptor, _ loadConfig: ModelLoadConfig) async throws
  -> EmbeddingBackendProtocol

// MARK: - Router state

private struct LoadedEntry: Sendable {
  let backend: SwiftLMBackendProtocol
  let loadID: UUID
  let backendObjectID: String
  let loadConfig: ModelLoadConfig
  var lastUsed: Date
  var inFlight: Int
  init(backend: SwiftLMBackendProtocol, loadConfig: ModelLoadConfig) {
    self.backend = backend
    self.loadID = UUID()
    self.backendObjectID = TraceContext.backendObjectID(of: backend)
    self.loadConfig = loadConfig
    self.lastUsed = Date()
    self.inFlight = 0
  }
}

private struct EmbeddingLoadedEntry: Sendable {
  let backend: EmbeddingBackendProtocol
  let loadID: UUID
  let backendObjectID: String
  let loadConfig: ModelLoadConfig
  var lastUsed: Date
  var inFlight: Int
  init(backend: EmbeddingBackendProtocol, loadID: UUID, loadConfig: ModelLoadConfig) {
    self.backend = backend
    self.loadID = loadID
    self.backendObjectID = TraceContext.backendObjectID(of: backend)
    self.loadConfig = loadConfig
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

/// A request waiting for a concurrency slot on a specific model. Lives only in
/// `ModelRouter`'s actor-isolated state. Resumed with `true` when a slot frees
/// and `false` when the wait times out or the model is torn down.
private final class ConcurrencyWaiter {
  let id: UUID
  let continuation: CheckedContinuation<Bool, Never>

  init(id: UUID, continuation: CheckedContinuation<Bool, Never>) {
    self.id = id
    self.continuation = continuation
  }
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
  /// Bytes of system memory the router keeps free at all times. A load is
  /// admitted only when at least this much remains available afterward.
  public let reserveBytes: Int64
  /// Reads live system memory on demand. Injected so admission stays pure and
  /// testable.
  public let memoryProbe: MemoryProbe
  /// How many times the post-eviction re-measure re-reads memory before giving
  /// up, and how long it waits between reads. Production waits out the brief OS
  /// page-reclaim lag; tests set both small so they do not actually sleep.
  public let settleAttempts: Int
  public let settleIntervalNanos: UInt64
  public let portRange: ClosedRange<Int>
  public let spawner: BackendSpawner
  public let embeddingSpawner: EmbeddingSpawner?
  public let chatMaxConcurrency: Int?
  /// The live embedding concurrency cap. Lowered by the battery throttle and
  /// restored to `configuredEmbeddingMaxConcurrency` when it releases.
  public private(set) var embeddingMaxConcurrency: Int?
  /// The configured embedding concurrency ceiling, never exceeded by the
  /// throttle and used as the restore target.
  private let configuredEmbeddingMaxConcurrency: Int?
  /// Inter-request embedding pacing in nanoseconds, set by the battery throttle.
  /// Read by the embeddings handler, which paces a request before releasing its
  /// slot so consecutive embeds leave a GPU-idle gap.
  private var embeddingPacingNanos: UInt64 = 0
  /// The active battery throttle level, applied to embedding backends as they
  /// load so a model spawned while throttled inherits the shrunken GPU cache.
  private var currentThrottleLevel: PowerThrottleLevel = .none
  /// True while the battery throttle is at `hard`, the stop level. New chat and
  /// embedding requests are refused with `RouteError.powerPaused`; in-flight
  /// requests already past the admission guard finish normally.
  private var powerHalted = false

  public let eventSink: @Sendable (RouterLifecycleEvent) -> Void

  private var loaded: [String: LoadedEntry] = [:]
  private var embeddingRoutes: [String: EmbeddingRouteState] = [:]
  private var allocatedPorts: Set<Int> = []

  /// FIFO waiters per model id, shared by chat and embedding routing. When a
  /// concurrency slot frees, the matching request-done path wakes the oldest
  /// waiter for that id, so contention queues rather than rejecting with a 429.
  private var concurrencyWaiters: [String: [ConcurrencyWaiter]] = [:]

  /// How long a queued request waits for a slot before the router gives up and
  /// surfaces `concurrencyLimitExceeded`. Settable for tests.
  private var queueTimeoutNanos: UInt64 = 120 * 1_000_000_000

  public init(
    reserveBytes: Int64,
    memoryProbe: @escaping MemoryProbe,
    portRange: ClosedRange<Int> = 5500...5599,
    spawner: @escaping BackendSpawner,
    embeddingSpawner: EmbeddingSpawner? = nil,
    chatMaxConcurrency: Int? = nil,
    embeddingMaxConcurrency: Int? = nil,
    settleAttempts: Int = 6,
    settleIntervalMillis: UInt64 = 250,
    eventSink: @escaping @Sendable (RouterLifecycleEvent) -> Void = { _ in }
  ) {
    self.reserveBytes = max(0, reserveBytes)
    self.memoryProbe = memoryProbe
    self.settleAttempts = max(1, settleAttempts)
    self.settleIntervalNanos = settleIntervalMillis * 1_000_000
    self.portRange = portRange
    self.spawner = spawner
    self.embeddingSpawner = embeddingSpawner
    self.chatMaxConcurrency = positiveLimit(chatMaxConcurrency)
    let normalizedEmbeddingLimit = positiveLimit(embeddingMaxConcurrency)
    self.embeddingMaxConcurrency = normalizedEmbeddingLimit
    self.configuredEmbeddingMaxConcurrency = normalizedEmbeddingLimit
    self.eventSink = eventSink
  }

  // MARK: - Snapshot

  public struct Snapshot: Sendable {
    public let loaded: [EvictionCandidate]
    public let allocatedBytes: Int64
  }

  /// Dry check used by the estimate path. Reports whether a load could be
  /// admitted, either because memory is already safe or because unloading idle
  /// models would restore the reserve. Has no side effects.
  public func canLoad(needing newBytes: Int64) -> Bool {
    let reading = memoryProbe()
    let deficit = HeadroomPolicy.bytesToFree(
      availableBytes: reading.availableBytes, needing: newBytes, reserveBytes: reserveBytes)
    if deficit == 0 {
      return true
    }
    let snap = snapshot()
    let plan = EvictionPolicy.planEvictionToFree(candidates: snap.loaded, bytesToFree: deficit)
    if plan.isEmpty {
      return false
    }
    let freed = projectedFreedBytes(plan: plan, in: snap)
    return reading.availableBytes + freed - newBytes >= reserveBytes
  }

  /// Current live memory reading. Used by the broker for status reporting.
  public func memoryReading() -> MemoryReading {
    memoryProbe()
  }

  // MARK: - Headroom enforcement

  /// Free idle models until the reserve is restored, then re-measure to confirm.
  /// Throws ``RouteError/insufficientHeadroom`` when the reserve cannot be met.
  private func ensureHeadroom(modelID: String, needing: Int64) async throws {
    var reading = memoryProbe()
    var deficit = HeadroomPolicy.bytesToFree(
      availableBytes: reading.availableBytes, needing: needing, reserveBytes: reserveBytes)
    if deficit == 0 && !reading.underPressure {
      return
    }

    let snap = snapshot()
    // Under pressure with the byte reserve already met, free at least one idle
    // model to relieve the pressure.
    let target = deficit > 0 ? deficit : 1
    let plan = EvictionPolicy.planEvictionToFree(candidates: snap.loaded, bytesToFree: target)
    if plan.isEmpty {
      // Nothing idle to free. When the byte reserve already holds and only the
      // pressure signal is set, there is nothing more to do, so allow the load.
      if deficit == 0 {
        return
      }
      throw RouteError.insufficientHeadroom(
        modelID: modelID, needing: needing, availableBytes: reading.availableBytes)
    }

    for id in plan {
      log.notice("router.headroom_evict model=\(id, privacy: .public)")
      evict(modelID: id)
    }

    reading = await settleAndRead(needing: needing)
    deficit = HeadroomPolicy.bytesToFree(
      availableBytes: reading.availableBytes, needing: needing, reserveBytes: reserveBytes)
    if deficit > 0 {
      throw RouteError.insufficientHeadroom(
        modelID: modelID, needing: needing, availableBytes: reading.availableBytes)
    }
  }

  /// Re-read memory after eviction, waiting out the brief OS page-reclaim lag.
  /// Returns as soon as the reserve is restored, or after the last attempt.
  private func settleAndRead(needing: Int64) async -> MemoryReading {
    var reading = memoryProbe()
    var attempt = 0
    while attempt < settleAttempts {
      let deficit = HeadroomPolicy.bytesToFree(
        availableBytes: reading.availableBytes, needing: needing, reserveBytes: reserveBytes)
      if deficit == 0 {
        return reading
      }
      try? await Task.sleep(nanoseconds: settleIntervalNanos)
      reading = memoryProbe()
      attempt += 1
    }
    return reading
  }

  /// Best-effort background pass: free idle models until the reserve is restored
  /// or no idle model remains. Used by the periodic loop and the memory-pressure
  /// event handler. Never throws; it frees what it can.
  public func enforceHeadroom() async {
    let reading = memoryProbe()
    let deficit = HeadroomPolicy.bytesToFree(
      availableBytes: reading.availableBytes, needing: 0, reserveBytes: reserveBytes)
    if deficit == 0 && !reading.underPressure {
      return
    }
    let snap = snapshot()
    let target = deficit > 0 ? deficit : 1
    let plan = EvictionPolicy.planEvictionToFree(candidates: snap.loaded, bytesToFree: target)
    for id in plan {
      log.notice("router.headroom_evict model=\(id, privacy: .public) reason=pressure")
      evict(modelID: id)
    }
  }

  private func projectedFreedBytes(plan: [String], in snap: Snapshot) -> Int64 {
    let ids = Set(plan)
    var freed: Int64 = 0
    for candidate in snap.loaded where ids.contains(candidate.modelID) {
      freed += candidate.sizeBytes
    }
    return freed
  }

  public func snapshot() -> Snapshot {
    pruneStoppedChatBackends()
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
          isEmbedding: false,
          loadConfig: entry.loadConfig
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
          isEmbedding: true,
          loadConfig: entry.loadConfig
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
    public let sizeBytes: Int64
    public let lastUsed: Date
    public let inFlightRequests: Int
    public let loadConfig: ModelLoadConfig

    public init(
      modelID: String,
      kind: BackendKind,
      loadID: UUID,
      backendObjectID: String,
      sizeBytes: Int64,
      lastUsed: Date,
      inFlightRequests: Int,
      loadConfig: ModelLoadConfig
    ) {
      self.modelID = modelID
      self.kind = kind
      self.loadID = loadID
      self.backendObjectID = backendObjectID
      self.sizeBytes = sizeBytes
      self.lastUsed = lastUsed
      self.inFlightRequests = inFlightRequests
      self.loadConfig = loadConfig
    }
  }

  /// Return `(loadID, backendObjectID)` for a loaded chat backend, or `nil`.
  public func chatLoadInfo(modelID: String) -> (loadID: UUID, backendObjectID: String)? {
    pruneStoppedChatBackends()
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
    pruneStoppedChatBackends()
    var infos: [LoadedModelInfo] = []
    for entry in loaded.values {
      infos.append(
        LoadedModelInfo(
          modelID: entry.backend.modelID,
          kind: .chat,
          loadID: entry.loadID,
          backendObjectID: entry.backendObjectID,
          sizeBytes: entry.backend.sizeBytes,
          lastUsed: entry.lastUsed,
          inFlightRequests: entry.inFlight,
          loadConfig: entry.loadConfig
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
          backendObjectID: entry.backendObjectID,
          sizeBytes: entry.backend.sizeBytes,
          lastUsed: entry.lastUsed,
          inFlightRequests: entry.inFlight,
          loadConfig: entry.loadConfig
        ))
    }
    return infos
  }

  // MARK: - Routing chat

  public enum RouteError: Error, Equatable {
    case noFreePort
    case insufficientHeadroom(modelID: String, needing: Int64, availableBytes: Int64)
    case backendLaunchFailed(modelID: String)
    case concurrencyLimitExceeded(modelID: String, limit: Int)
    case loadConfigConflict(modelID: String)
    case wrongKindForChat(modelID: String)
    case wrongKindForEmbedding(modelID: String)
    case embeddingSpawnerMissing
    case unsupportedEmbeddingBackend(modelID: String, reason: String)
    case powerPaused(reason: String)
  }

  public func routeAndBegin(
    _ model: ModelDescriptor,
    loadConfig: ModelLoadConfig? = nil,
    requestID: UUID? = nil
  ) async throws -> SwiftLMBackendProtocol {
    if powerHalted {
      throw RouteError.powerPaused(reason: "battery")
    }
    pruneStoppedChatBackends()
    BackendTrace.notice(
      phase: TracePhase.Router.routeBegin.rawValue,
      context: TraceContext(modelID: model.id, modelKind: .chat, requestID: requestID),
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
          backendObjectID: resultBackendObj,
          requestID: requestID
        ),
        snapshot: .current()
      )
    }
    guard model.kind != .embedding else {
      throw RouteError.wrongKindForChat(modelID: model.id)
    }
    let effectiveLoadConfig = (loadConfig ?? .default).normalized(for: .chat)
    chatAcquire: while var entry = loaded[model.id] {
      if loadConfig != nil && entry.loadConfig != effectiveLoadConfig {
        if entry.inFlight > 0 {
          throw RouteError.loadConfigConflict(modelID: model.id)
        }
        unload(modelID: model.id, disposition: .unloaded)
        break chatAcquire
      }
      if let chatMaxConcurrency, entry.inFlight >= chatMaxConcurrency {
        // Queue instead of rejecting: wait for a slot to free, then re-check.
        if await waitForConcurrencySlot(modelID: model.id) == false {
          throw RouteError.concurrencyLimitExceeded(modelID: model.id, limit: chatMaxConcurrency)
        }
        continue chatAcquire
      }
      entry.lastUsed = Date()
      entry.inFlight += 1
      loaded[model.id] = entry
      resultLoadID = entry.loadID
      resultBackendObj = entry.backendObjectID
      return entry.backend
    }

    try await ensureHeadroom(modelID: model.id, needing: model.sizeBytes)

    guard let port = firstFreePort() else {
      throw RouteError.noFreePort
    }
    allocatedPorts.insert(port)

    let backend: SwiftLMBackendProtocol
    do {
      backend = try spawner(model, port, effectiveLoadConfig)
      try backend.launch()
    } catch {
      allocatedPorts.remove(port)
      let errorDescription = String(describing: error)
      log.error(
        "router.backend_launch_failed model=\(model.id, privacy: .public) err=\(errorDescription, privacy: .public)"
      )
      eventSink(.backendLaunchFailed(modelID: model.id, errorDescription: errorDescription))
      throw RouteError.backendLaunchFailed(modelID: model.id)
    }

    var entry = LoadedEntry(backend: backend, loadConfig: effectiveLoadConfig)
    entry.inFlight = 1
    loaded[model.id] = entry
    resultLoadID = entry.loadID
    resultBackendObj = entry.backendObjectID
    log.notice(
      "router.model_spawned model=\(model.id, privacy: .public) port=\(port, privacy: .public)")
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

  private func pruneStoppedChatBackends() {
    let stoppedEntries = loaded.filter { _, entry in
      !entry.backend.isRunning
    }
    for (modelID, entry) in stoppedEntries {
      let port = entry.backend.port
      loaded.removeValue(forKey: modelID)
      allocatedPorts.remove(port)
      log.notice(
        "router.model_pruned model=\(modelID, privacy: .public) port=\(port, privacy: .public) reason=backend_exited"
      )
      BackendTrace.notice(
        phase: TracePhase.Router.modelUnloaded.rawValue,
        context: TraceContext(
          modelID: modelID,
          modelKind: .chat,
          loadID: entry.loadID,
          backendObjectID: entry.backendObjectID
        ),
        snapshot: .current(),
        extras: ["port": "\(port)", "reason": "backend_exited"]
      )
      eventSink(.modelUnloaded(modelID: modelID, port: port))
    }
  }

  // MARK: - Routing embeddings

  public func routeEmbeddingAndBegin(
    _ model: ModelDescriptor,
    loadConfig: ModelLoadConfig? = nil
  ) async throws -> EmbeddingBackendProtocol {
    if powerHalted {
      throw RouteError.powerPaused(reason: "battery")
    }
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
    let effectiveLoadConfig = (loadConfig ?? .default).normalized(for: .embedding)

    embeddingAcquire: while let state = embeddingRoutes[model.id] {
      switch state {
      case .loaded(var entry):
        if loadConfig != nil && entry.loadConfig != effectiveLoadConfig {
          if entry.inFlight > 0 {
            throw RouteError.loadConfigConflict(modelID: model.id)
          }
          unload(modelID: model.id, disposition: .unloaded)
          break embeddingAcquire
        }
        if let embeddingMaxConcurrency, entry.inFlight >= embeddingMaxConcurrency {
          // Queue instead of rejecting: wait for a slot to free, then re-check.
          if await waitForConcurrencySlot(modelID: model.id) == false {
            throw RouteError.concurrencyLimitExceeded(
              modelID: model.id,
              limit: embeddingMaxConcurrency
            )
          }
          continue embeddingAcquire
        }
        entry.lastUsed = Date()
        entry.inFlight += 1
        embeddingRoutes[model.id] = .loaded(entry)
        resultLoadID = entry.loadID
        resultBackendObj = entry.backendObjectID
        return entry.backend
      case .loading(let loading):
        log.debug(
          "router.embedding_load_wait model=\(model.id, privacy: .public) load_id=\(loading.id.uuidString, privacy: .public)"
        )
        let backend = try await finishEmbeddingLoad(
          model: model,
          loading: loading,
          loadConfig: effectiveLoadConfig
        )
        if let info = embeddingLoadInfo(modelID: model.id) {
          resultLoadID = info.loadID
          resultBackendObj = info.backendObjectID
        }
        return backend
      }
    }

    try await ensureHeadroom(modelID: model.id, needing: model.sizeBytes)

    let loadTask = Task {
      try await embeddingSpawner(model, effectiveLoadConfig)
    }
    let loading = EmbeddingLoadingEntry(task: loadTask)
    embeddingRoutes[model.id] = .loading(loading)
    let backend = try await finishEmbeddingLoad(
      model: model,
      loading: loading,
      loadConfig: effectiveLoadConfig
    )
    if let info = embeddingLoadInfo(modelID: model.id) {
      resultLoadID = info.loadID
      resultBackendObj = info.backendObjectID
    }
    return backend
  }

  public func requestDone(modelID: String, requestID: UUID? = nil) {
    guard var entry = loaded[modelID] else {
      log.fault(
        """
        router.request_done_unknown_chat_model model=\(modelID, privacy: .public) \
        request_id=\(requestID?.uuidString ?? "none", privacy: .public)
        """
      )
      return
    }
    if entry.inFlight > 0 { entry.inFlight -= 1 }
    entry.lastUsed = Date()
    loaded[modelID] = entry
    wakeNextConcurrencyWaiter(modelID: modelID)
    log.notice(
      """
      router.request_done model=\(modelID, privacy: .public) \
      request_id=\(requestID?.uuidString ?? "none", privacy: .public) \
      in_flight=\(entry.inFlight, privacy: .public)
      """
    )
    BackendTrace.notice(
      phase: TracePhase.Router.requestDone.rawValue,
      context: TraceContext(
        modelID: modelID,
        modelKind: .chat,
        loadID: entry.loadID,
        backendObjectID: entry.backendObjectID,
        requestID: requestID
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
    wakeNextConcurrencyWaiter(modelID: modelID)
    log.debug(
      "router.embedding_request_done model=\(modelID, privacy: .public) in_flight=\(entry.inFlight, privacy: .public)"
    )
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

  // MARK: - Concurrency queue

  /// Set the queue wait timeout. Intended for tests, which use a short value so
  /// the timeout path does not stall the suite.
  public func setQueueTimeoutNanos(_ nanos: UInt64) {
    queueTimeoutNanos = nanos
  }

  /// Suspend until a slot for `modelID` frees. Returns `true` when woken to
  /// retry the capacity check, `false` when the wait timed out or the model was
  /// torn down. The caller re-checks state after a `true` result, since a fresh
  /// request may have taken the freed slot first.
  private func waitForConcurrencySlot(modelID: String) async -> Bool {
    let waiterID = UUID()
    let timeoutNanos = queueTimeoutNanos
    return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
      concurrencyWaiters[modelID, default: []].append(
        ConcurrencyWaiter(id: waiterID, continuation: continuation))
      Task.detached { [weak self] in
        try? await Task.sleep(nanoseconds: timeoutNanos)
        await self?.expireConcurrencyWaiter(modelID: modelID, waiterID: waiterID)
      }
    }
  }

  /// Resume a still-queued waiter with `false` after its timeout elapsed. A
  /// no-op if the waiter was already woken or drained, since its id is gone.
  private func expireConcurrencyWaiter(modelID: String, waiterID: UUID) {
    guard var waiters = concurrencyWaiters[modelID],
      let index = waiters.firstIndex(where: { $0.id == waiterID })
    else {
      return
    }
    let waiter = waiters.remove(at: index)
    concurrencyWaiters[modelID] = waiters.isEmpty ? nil : waiters
    waiter.continuation.resume(returning: false)
  }

  /// Wake the oldest waiter for `modelID`, if any, after a slot frees.
  private func wakeNextConcurrencyWaiter(modelID: String) {
    guard var waiters = concurrencyWaiters[modelID], !waiters.isEmpty else {
      return
    }
    let waiter = waiters.removeFirst()
    concurrencyWaiters[modelID] = waiters.isEmpty ? nil : waiters
    waiter.continuation.resume(returning: true)
  }

  /// Resume every waiter for `modelID` with `false`, used when the model is
  /// unloaded or evicted so no queued request hangs forever.
  private func drainConcurrencyWaiters(modelID: String) {
    guard let waiters = concurrencyWaiters.removeValue(forKey: modelID) else {
      return
    }
    for waiter in waiters {
      waiter.continuation.resume(returning: false)
    }
  }

  // MARK: - Battery throttle

  /// Inter-request embedding pacing in nanoseconds for the embeddings handler to
  /// sleep before releasing a request's slot. Zero when not throttled.
  public func embeddingPacing() -> UInt64 {
    embeddingPacingNanos
  }

  /// True while the battery throttle is at `hard` and the router refuses new
  /// work. Exposed for tests and diagnostics.
  public func isPowerHalted() -> Bool {
    powerHalted
  }

  /// Apply a battery throttle level: cap embedding concurrency, set inter-request
  /// pacing, forward the level to every loaded embedding backend so it can shrink
  /// the GPU cache, and at `hard` halt admission so new chat and embedding
  /// requests are refused while in-flight requests drain. Concurrency is never
  /// raised above the configured ceiling, and `none` restores the configured cap
  /// with zero pacing and clears the halt.
  public func applyPowerThrottle(_ level: PowerThrottleLevel) {
    let concurrency: Int?
    let pacingNanos: UInt64
    switch level {
    case .none:
      concurrency = configuredEmbeddingMaxConcurrency
      pacingNanos = 0
    case .mild:
      concurrency = cappedEmbeddingConcurrency(ceiling: 2)
      pacingNanos = 75_000_000
    case .hard:
      concurrency = cappedEmbeddingConcurrency(ceiling: 1)
      pacingNanos = 250_000_000
    }
    embeddingMaxConcurrency = concurrency
    embeddingPacingNanos = pacingNanos
    currentThrottleLevel = level
    powerHalted = (level == .hard)
    for state in embeddingRoutes.values {
      if case .loaded(let entry) = state {
        entry.backend.applyPowerThrottle(level)
      }
    }
    log.notice(
      """
      router.power_throttle_applied level=\(level.rawValue, privacy: .public) \
      halted=\(self.powerHalted, privacy: .public) \
      embedding_concurrency=\(concurrency ?? -1, privacy: .public) \
      pacing_ms=\(pacingNanos / 1_000_000, privacy: .public)
      """
    )
  }

  /// The throttled concurrency: `ceiling`, clamped so it never exceeds the
  /// configured ceiling. Returns `ceiling` when no limit was configured.
  private func cappedEmbeddingConcurrency(ceiling: Int) -> Int? {
    guard let configured = configuredEmbeddingMaxConcurrency else {
      return ceiling
    }
    return min(configured, ceiling)
  }

  public func unload(modelID: String) {
    unload(modelID: modelID, disposition: .unloaded)
  }

  private func evict(modelID: String) {
    unload(modelID: modelID, disposition: .evicted)
  }

  private func unload(modelID: String, disposition: UnloadDisposition) {
    // Release any queued waiters first so none hangs on a model going away.
    drainConcurrencyWaiters(modelID: modelID)
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
        log.notice(
          "router.model_unloaded model=\(modelID, privacy: .public) port=\(port, privacy: .public)")
        BackendTrace.notice(
          phase: TracePhase.Router.modelUnloaded.rawValue,
          context: traceCtx,
          snapshot: .current(),
          extras: ["port": "\(port)", "reason": "unloaded"]
        )
        eventSink(.modelUnloaded(modelID: modelID, port: port))
      case .evicted:
        log.notice(
          "router.model_evicted model=\(modelID, privacy: .public) port=\(port, privacy: .public)")
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
        log.notice(
          "router.embedding_load_cancelled model=\(modelID, privacy: .public) load_id=\(loading.id.uuidString, privacy: .public)"
        )
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
    loading: EmbeddingLoadingEntry,
    loadConfig: ModelLoadConfig
  ) async throws -> EmbeddingBackendProtocol {
    let backend: EmbeddingBackendProtocol
    do {
      backend = try await loading.task.value
    } catch let error as UnsupportedEmbeddingBackendError {
      let reason = error.description
      if clearEmbeddingLoadingIfCurrent(modelID: model.id, loading: loading) {
        log.error(
          "router.embedding_backend_unsupported model=\(model.id, privacy: .public) load_id=\(loading.id.uuidString, privacy: .public) err=\(reason, privacy: .public)"
        )
        eventSink(.embeddingBackendUnsupported(modelID: model.id, reason: reason))
      }
      throw RouteError.unsupportedEmbeddingBackend(modelID: model.id, reason: reason)
    } catch {
      let errorDescription = String(describing: error)
      if clearEmbeddingLoadingIfCurrent(modelID: model.id, loading: loading) {
        log.error(
          "router.embedding_launch_failed model=\(model.id, privacy: .public) load_id=\(loading.id.uuidString, privacy: .public) err=\(errorDescription, privacy: .public)"
        )
        eventSink(.embeddingLaunchFailed(modelID: model.id, errorDescription: errorDescription))
      }
      throw RouteError.backendLaunchFailed(modelID: model.id)
    }

    guard let state = embeddingRoutes[model.id] else {
      backend.shutdown()
      log.notice(
        "router.embedding_load_discarded model=\(model.id, privacy: .public) load_id=\(loading.id.uuidString, privacy: .public) reason=unloaded"
      )
      throw RouteError.backendLaunchFailed(modelID: model.id)
    }

    switch state {
    case .loaded(var entry):
      // Another request already serves this model. Queue for a slot rather than
      // rejecting, re-reading the entry after each wait since it may change.
      while let embeddingMaxConcurrency, entry.inFlight >= embeddingMaxConcurrency {
        if await waitForConcurrencySlot(modelID: model.id) == false {
          throw RouteError.concurrencyLimitExceeded(
            modelID: model.id,
            limit: embeddingMaxConcurrency
          )
        }
        guard case .loaded(let refreshed)? = embeddingRoutes[model.id] else {
          throw RouteError.backendLaunchFailed(modelID: model.id)
        }
        entry = refreshed
      }
      entry.lastUsed = Date()
      entry.inFlight += 1
      embeddingRoutes[model.id] = .loaded(entry)
      return entry.backend
    case .loading(let current) where current.id == loading.id:
      var entry = EmbeddingLoadedEntry(
        backend: backend,
        loadID: loading.id,
        loadConfig: loadConfig
      )
      entry.inFlight = 1
      embeddingRoutes[model.id] = .loaded(entry)
      // A model spawned while throttled inherits the active throttle so its GPU
      // cache is shrunk on load, not only on the next level change.
      backend.applyPowerThrottle(currentThrottleLevel)
      log.notice(
        "router.embedding_spawned model=\(model.id, privacy: .public) load_id=\(loading.id.uuidString, privacy: .public)"
      )
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
      log.fault(
        "router.embedding_load_stale model=\(model.id, privacy: .public) load_id=\(loading.id.uuidString, privacy: .public)"
      )
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

private func positiveLimit(_ value: Int?) -> Int? {
  guard let value, value > 0 else {
    return nil
  }
  return value
}
