//
//  ModelRouter.swift
//  SwiftLMRuntime
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-04-18.
//  Copyright © 2026, all rights reserved.
//

import AppLogger
import Foundation
import SwiftLMCore
import SwiftLMHostProtocol
import SwiftLMTrace

private let log = AppLogger.logger(category: "ModelRouter")

private typealias RouteKind = SwiftLMTrace.BackendKind
private typealias WireThrottleLevel = SwiftLMHostProtocol.ThrottleLevel

// MARK: - Spawner

public typealias ModelServerSpawner =
  @Sendable (
    _ model: ModelDescriptor,
    _ kind: SwiftLMTrace.BackendKind,
    _ loadConfig: ModelLoadConfig
  ) async throws -> ModelServer

// MARK: - Router state

private struct LoadedEntry: Sendable {
  let server: ModelServer
  let kind: RouteKind
  let loadID: UUID
  let backendObjectID: String
  let loadConfig: ModelLoadConfig
  var lastUsed: Date
  var inFlight: Int

  init(
    server: ModelServer,
    kind: RouteKind,
    loadID: UUID = UUID(),
    loadConfig: ModelLoadConfig
  ) {
    self.server = server
    self.kind = kind
    self.loadID = loadID
    self.backendObjectID = TraceContext.backendObjectID(of: server)
    self.loadConfig = loadConfig
    self.lastUsed = Date()
    self.inFlight = 0
  }
}

private final class LoadingEntry: Sendable {
  let id: UUID
  let kind: RouteKind
  let task: Task<ModelServer, Error>

  init(kind: RouteKind, task: Task<ModelServer, Error>) {
    self.id = UUID()
    self.kind = kind
    self.task = task
  }
}

private enum RouteState: Sendable {
  case loading(LoadingEntry)
  case loaded(LoadedEntry)
}

// MARK: - RoutedServer

/// A routed model server plus its trace identity, returned by the admission helpers.
private struct RoutedServer {
  let server: ModelServer
  let loadID: UUID?
  let backendObj: String?
}

// MARK: - LoadedDecision

/// The outcome of trying to admit a request to an already-loaded model.
private enum LoadedDecision {
  /// The current entry was torn down; load a fresh one.
  case reload
  /// A concurrency slot wait completed; re-evaluate from the top.
  case retry
  case served(RoutedServer)
}

/// A request parked until it can proceed, either waiting for a concurrency slot
/// on a specific model or for memory to admit a load. Lives only in
/// `ModelRouter`'s actor-isolated state. Resumed with `true` when woken to retry
/// and `false` when the wait times out or the model is torn down. `priority` is
/// the requestor's load priority, used to wake admission waiters highest first;
/// concurrency-slot waiters share a single default and wake FIFO.
private final class ConcurrencyWaiter {
  let id: UUID
  let priority: Int
  let continuation: CheckedContinuation<Bool, Never>

  init(id: UUID, priority: Int, continuation: CheckedContinuation<Bool, Never>) {
    self.id = id
    self.priority = priority
    self.continuation = continuation
  }
}

private enum UnloadDisposition {
  case evicted
  /// Reclaimed to make room for a strictly higher-priority load.
  case preempted
  case unloaded
}

public enum RouterLifecycleEvent: Sendable, Equatable {
  case modelSpawned(modelID: String, kind: SwiftLMTrace.BackendKind)
  case modelUnloaded(modelID: String, kind: SwiftLMTrace.BackendKind)
  case modelEvicted(modelID: String, kind: SwiftLMTrace.BackendKind)
  case modelPreempted(modelID: String, kind: SwiftLMTrace.BackendKind)
  case modelLoadCancelled(modelID: String, kind: SwiftLMTrace.BackendKind, loadID: String)
  case backendLaunchFailed(
    modelID: String,
    kind: SwiftLMTrace.BackendKind,
    errorDescription: String
  )
}

// MARK: - ModelRouter

/// Tracks loaded model servers and routes every backend kind through the same
/// lifecycle, admission, concurrency, eviction, and idle-unload path.
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
  /// How long a just-preempted model is refused a contended reload, so the
  /// client that kept it hot backs off instead of immediately re-contending.
  public let preemptCooldownNanos: UInt64
  public let spawner: ModelServerSpawner

  /// Nanoseconds per millisecond, for converting the injected millisecond knobs.
  private static let nanosecondsPerMillisecond: UInt64 = 1_000_000
  /// Nanoseconds per second, for converting an elapsed-seconds interval.
  private static let nanosecondsPerSecond: Double = 1_000_000_000
  /// Reserved waiter key for memory-admission waiters, distinct from any model id.
  private static let admissionWaiterKey = "\u{0}admission"
  /// Most admission waiters parked at once before new ones are refused immediately.
  private static let maxAdmissionWaiters = 256
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
  /// The active battery throttle level, applied to embedding servers as they
  /// load so a model spawned while throttled inherits the shrunken GPU cache.
  private var currentThrottleLevel: PowerThrottleLevel = .none
  /// True while the battery throttle is at `hard`, the stop level. New chat and
  /// embedding requests are refused with `RouteError.powerPaused`; in-flight
  /// requests already past the admission guard finish normally.
  private var powerHalted = false

  public let eventSink: @Sendable (RouterLifecycleEvent) -> Void

  private var routes: [String: RouteState] = [:]

  /// FIFO waiters per model id, shared by all backend kinds. When a concurrency
  /// slot frees, the matching request-done path wakes the oldest waiter for
  /// that id, so contention queues rather than rejecting with a 429.
  private var concurrencyWaiters: [String: [ConcurrencyWaiter]] = [:]

  /// Models currently being preempted. While a model id is in this set its new
  /// requests are refused so its in-flight count can drain to zero, and the
  /// request-done path reclaims each one the moment it reaches zero in-flight.
  private var draining: Set<String> = []

  /// When each model was last preempted, used to gate contended reloads during
  /// the cooldown window.
  private var preemptedAt: [String: Date] = [:]

  /// The whole-request wait budget: how long a request may park for memory or a
  /// concurrency slot before the router gives up. Set from `init` and settable
  /// for tests.
  private var queueTimeoutNanos: UInt64

  @preconcurrency
  public init(
    reserveBytes: Int64,
    memoryProbe: @escaping MemoryProbe,
    spawner: @escaping ModelServerSpawner,
    chatMaxConcurrency: Int? = nil,
    embeddingMaxConcurrency: Int? = nil,
    settleAttempts: Int = 6,
    settleIntervalMillis: UInt64 = 250,
    preemptCooldownMillis: UInt64 = 5_000,
    requestWaitTimeoutMillis: UInt64 = 120_000,
    eventSink: @escaping @Sendable (RouterLifecycleEvent) -> Void = { _ in }
  ) {
    self.reserveBytes = max(0, reserveBytes)
    self.memoryProbe = memoryProbe
    self.settleAttempts = max(1, settleAttempts)
    self.settleIntervalNanos = settleIntervalMillis * Self.nanosecondsPerMillisecond
    self.preemptCooldownNanos = preemptCooldownMillis * Self.nanosecondsPerMillisecond
    self.queueTimeoutNanos = requestWaitTimeoutMillis * Self.nanosecondsPerMillisecond
    self.spawner = spawner
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
  public func canLoad(needing newBytes: Int64, requestorPriority: Int = .max) -> Bool {
    let reading = memoryProbe()
    let deficit = HeadroomPolicy.bytesToFree(
      availableBytes: reading.availableBytes, needing: newBytes, reserveBytes: reserveBytes)
    if deficit == 0 {
      return true
    }
    let snap = snapshot()
    let plan = EvictionPolicy.planEvictionToFree(
      candidates: snap.loaded, bytesToFree: deficit, requestorPriority: requestorPriority)
    if plan.isEmpty {
      return false
    }
    let freed = projectedFreedBytes(plan: plan.all, in: snap)
    return reading.availableBytes + freed - newBytes >= reserveBytes
  }

  /// Current live memory reading. Used by the broker for status reporting.
  public func memoryReading() -> MemoryReading {
    memoryProbe()
  }

  // MARK: - Headroom enforcement

  /// Reclaim room for a load requested at `requestorPriority`: unload idle
  /// victims, drain-and-preempt busy lower-priority victims, then re-measure to
  /// confirm. Throws ``RouteError/insufficientHeadroom`` when the reserve cannot
  /// be met.
  private func ensureHeadroom(
    modelID: String,
    needing: Int64,
    loadConfig: ModelLoadConfig,
    kind: RouteKind
  ) async throws {
    try enforceReloadCooldown(modelID: modelID, needing: needing)
    let requestorPriority = loadConfig.effectivePriority(for: loadConfigKind(kind))
    var reading = memoryProbe()
    var deficit = HeadroomPolicy.bytesToFree(
      availableBytes: reading.availableBytes, needing: needing, reserveBytes: reserveBytes)
    if deficit == 0, !reading.underPressure {
      return
    }

    let snap = snapshot()
    // Under pressure with the byte reserve already met, free at least one idle
    // model to relieve the pressure.
    let target = deficit > 0 ? deficit : 1
    let plan = EvictionPolicy.planEvictionToFree(
      candidates: snap.loaded, bytesToFree: target, requestorPriority: requestorPriority)
    if plan.isEmpty {
      // Nothing eligible to free. When the byte reserve already holds and only
      // the pressure signal is set, there is nothing more to do, so allow the load.
      if deficit == 0 {
        return
      }
      throw RouteError.insufficientHeadroom(
        modelID: modelID, needing: needing, availableBytes: reading.availableBytes)
    }

    for id in plan.idle {
      log.notice("router.headroom_evict model=\(id, privacy: .public) reason=idle")
      evict(modelID: id)
    }
    // Block new requests to busy lower-priority victims so their in-flight count
    // can drain; the request-done path preempts each one the moment it reaches
    // zero. The settle window below is the drain budget.
    for id in plan.busy {
      draining.insert(id)
      log.notice("router.preempt_drain_begin model=\(id, privacy: .public)")
    }

    reading = await settleAndRead(needing: needing)
    deficit = HeadroomPolicy.bytesToFree(
      availableBytes: reading.availableBytes, needing: needing, reserveBytes: reserveBytes)
    if deficit > 0 {
      // The drain window elapsed without freeing enough; force-stop any victim
      // still serving requests, then re-measure.
      for id in plan.busy where draining.contains(id) {
        log.notice("router.preempt_drain_timeout model=\(id, privacy: .public)")
        unload(modelID: id, disposition: .preempted)
      }
      reading = await settleAndRead(needing: needing)
      deficit = HeadroomPolicy.bytesToFree(
        availableBytes: reading.availableBytes, needing: needing, reserveBytes: reserveBytes)
    }
    for id in plan.busy {
      draining.remove(id)
    }
    if deficit > 0 {
      throw RouteError.insufficientHeadroom(
        modelID: modelID, needing: needing, availableBytes: reading.availableBytes)
    }
  }

  /// Refuse a contended reload of a model still inside its preemption cooldown.
  /// A reload is allowed when memory is already free, so the model returns as
  /// soon as the higher-priority load that displaced it releases its memory.
  private func enforceReloadCooldown(modelID: String, needing: Int64) throws {
    guard let stamp = preemptedAt[modelID] else {
      return
    }
    let elapsedNanos = UInt64(max(0, Date().timeIntervalSince(stamp)) * Self.nanosecondsPerSecond)
    if elapsedNanos >= preemptCooldownNanos {
      preemptedAt[modelID] = nil
      return
    }
    let reading = memoryProbe()
    let deficit = HeadroomPolicy.bytesToFree(
      availableBytes: reading.availableBytes, needing: needing, reserveBytes: reserveBytes)
    if deficit > 0 {
      let elapsedMillis = elapsedNanos / Self.nanosecondsPerMillisecond
      log.notice(
        "router.reload_cooldown model=\(modelID, privacy: .public) elapsed_ms=\(elapsedMillis, privacy: .public)"
      )
      throw RouteError.modelYielding(modelID: modelID)
    }
    preemptedAt[modelID] = nil
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
  public func enforceHeadroom() {
    let reading = memoryProbe()
    let deficit = HeadroomPolicy.bytesToFree(
      availableBytes: reading.availableBytes, needing: 0, reserveBytes: reserveBytes)
    if deficit == 0, !reading.underPressure {
      return
    }
    let snap = snapshot()
    let target = deficit > 0 ? deficit : 1
    // Background pressure relief has no requestor to preempt for, so it only
    // unloads idle models and never drains a busy one.
    let plan = EvictionPolicy.planEvictionToFree(candidates: snap.loaded, bytesToFree: target)
    for id in plan.idle {
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
    pruneStoppedServers()
    var total: Int64 = 0
    var candidates: [EvictionCandidate] = []
    for state in routes.values {
      guard case .loaded(let entry) = state else {
        continue
      }
      total += entry.server.sizeBytes
      candidates.append(
        EvictionCandidate(
          modelID: entry.server.modelID,
          sizeBytes: entry.server.sizeBytes,
          lastUsed: entry.lastUsed,
          inFlightRequests: entry.inFlight,
          isEmbedding: entry.kind == .embedding,
          priority: entry.loadConfig.effectivePriority(for: loadConfigKind(entry.kind)),
          pinned: entry.loadConfig.isPinned,
          loadConfig: entry.loadConfig
        ))
    }
    return Snapshot(loaded: candidates, allocatedBytes: total)
  }

  // MARK: - Trace identity

  /// Identity record for a single loaded model server. Used by the broker layer
  /// to attach `load_id` and `backend_obj` fields to per-request trace lines,
  /// and by the background sampler to enumerate currently resident servers.
  public struct LoadedModelInfo: Sendable {
    public let modelID: String
    public let kind: SwiftLMTrace.BackendKind
    public let loadID: UUID
    public let backendObjectID: String
    public let sizeBytes: Int64
    public let lastUsed: Date
    public let inFlightRequests: Int
    public let loadConfig: ModelLoadConfig

    public init(
      modelID: String,
      kind: SwiftLMTrace.BackendKind,
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

  /// Return `(loadID, backendObjectID)` for a loaded model server, or `nil`.
  public func loadInfo(
    modelID: String,
    kind: SwiftLMTrace.BackendKind
  ) -> (loadID: UUID, backendObjectID: String)? {
    pruneStoppedServers()
    guard let state = routes[modelID], case .loaded(let entry) = state, entry.kind == kind else {
      return nil
    }
    return (entry.loadID, entry.backendObjectID)
  }

  public func chatLoadInfo(modelID: String) -> (loadID: UUID, backendObjectID: String)? {
    loadInfo(modelID: modelID, kind: .chat)
  }

  public func embeddingLoadInfo(modelID: String) -> (loadID: UUID, backendObjectID: String)? {
    loadInfo(modelID: modelID, kind: .embedding)
  }

  public func videoLoadInfo(modelID: String) -> (loadID: UUID, backendObjectID: String)? {
    loadInfo(modelID: modelID, kind: .video)
  }

  /// Enumerate every currently resident model server.
  public func loadedModelInfos() -> [LoadedModelInfo] {
    pruneStoppedServers()
    var infos: [LoadedModelInfo] = []
    for state in routes.values {
      guard case .loaded(let entry) = state else {
        continue
      }
      infos.append(
        LoadedModelInfo(
          modelID: entry.server.modelID,
          kind: entry.kind,
          loadID: entry.loadID,
          backendObjectID: entry.backendObjectID,
          sizeBytes: entry.server.sizeBytes,
          lastUsed: entry.lastUsed,
          inFlightRequests: entry.inFlight,
          loadConfig: entry.loadConfig
        ))
    }
    return infos
  }

  // MARK: - Routing

  public enum RouteError: Error, Equatable {
    case insufficientHeadroom(modelID: String, needing: Int64, availableBytes: Int64)
    case backendLaunchFailed(modelID: String)
    case concurrencyLimitExceeded(modelID: String, limit: Int)
    case loadConfigConflict(modelID: String)
    case wrongKindForChat(modelID: String)
    case wrongKindForEmbedding(modelID: String)
    case powerPaused(reason: String)
    /// The model is being preempted, or was just preempted and is in its reload
    /// cooldown, for a higher-priority load. Retriable once that load releases.
    case modelYielding(modelID: String)
  }

  public func routeAndBegin(
    _ model: ModelDescriptor,
    kind: SwiftLMTrace.BackendKind = .chat,
    loadConfig: ModelLoadConfig? = nil,
    requestID: UUID? = nil
  ) async throws -> ModelServer {
    let effectiveLoadConfig = (loadConfig ?? .default).normalized(for: loadConfigKind(kind))
    let requestorPriority = effectiveLoadConfig.effectivePriority(for: loadConfigKind(kind))
    let deadline = Date().addingTimeInterval(
      Double(queueTimeoutNanos) / Self.nanosecondsPerSecond)
    BackendTrace.notice(
      phase: TracePhase.Router.routeBegin.rawValue,
      context: TraceContext(modelID: model.id, modelKind: kind, requestID: requestID),
      snapshot: .current()
    )
    var routed: RoutedServer?
    defer {
      BackendTrace.notice(
        phase: TracePhase.Router.routeEnd.rawValue,
        context: TraceContext(
          modelID: model.id,
          modelKind: kind,
          loadID: routed?.loadID,
          backendObjectID: routed?.backendObj,
          requestID: requestID
        ),
        snapshot: .current()
      )
    }
    while true {
      do {
        let result = try await attemptRoute(
          model, kind: kind, loadConfig: loadConfig, deadline: deadline)
        routed = result
        return result.server
      } catch let error as RouteError where Self.isAdmissionFailure(error) {
        // Cannot be served right now but may be once memory frees: park in the
        // admission queue until woken or the request's deadline passes.
        if Date() >= deadline {
          throw error
        }
        if await waitForAdmission(priority: requestorPriority, until: deadline) == false {
          throw error
        }
      }
    }
  }

  /// Whether `error` means "cannot be served right now but may be retried once
  /// memory frees": the load cannot get headroom, or a model is mid-preemption or
  /// in its reload cooldown. Everything else surfaces immediately.
  private static func isAdmissionFailure(_ error: RouteError) -> Bool {
    switch error {
    case .insufficientHeadroom, .modelYielding:
      return true
    case .backendLaunchFailed, .concurrencyLimitExceeded, .loadConfigConflict,
      .wrongKindForChat, .wrongKindForEmbedding, .powerPaused:
      return false
    }
  }

  private func attemptRoute(
    _ model: ModelDescriptor,
    kind: SwiftLMTrace.BackendKind,
    loadConfig: ModelLoadConfig?,
    deadline: Date
  ) async throws -> RoutedServer {
    if powerHalted {
      throw RouteError.powerPaused(reason: "battery")
    }
    pruneStoppedServers()
    try validateRouteKind(model: model, kind: kind)
    let effectiveLoadConfig = (loadConfig ?? .default).normalized(for: loadConfigKind(kind))
    routeAcquire: while let state = routes[model.id] {
      switch state {
      case .loaded(let entry):
        let decision = try await admitLoaded(
          entry: entry,
          model: model,
          kind: kind,
          loadConfig: loadConfig,
          deadline: deadline)
        switch decision {
        case .served(let routed):
          return routed
        case .reload:
          break routeAcquire
        case .retry:
          continue routeAcquire
        }
      case .loading(let loading):
        return try await awaitLoading(
          loading: loading,
          model: model,
          kind: kind,
          loadConfig: effectiveLoadConfig,
          deadline: deadline)
      }
    }
    return try await spawnAndBegin(
      model: model, kind: kind, loadConfig: effectiveLoadConfig, deadline: deadline)
  }

  /// Decide how to serve a request that found `model` already loaded: admit it,
  /// tear the entry down to reload, or wait for a concurrency slot and retry.
  private func admitLoaded(
    entry: LoadedEntry,
    model: ModelDescriptor,
    kind: RouteKind,
    loadConfig: ModelLoadConfig?,
    deadline: Date
  ) async throws -> LoadedDecision {
    if draining.contains(model.id) {
      throw RouteError.modelYielding(modelID: model.id)
    }
    let effectiveLoadConfig = (loadConfig ?? .default).normalized(for: loadConfigKind(kind))
    if entry.kind != kind || (loadConfig != nil && entry.loadConfig != effectiveLoadConfig) {
      if entry.inFlight > 0 {
        throw RouteError.loadConfigConflict(modelID: model.id)
      }
      unload(modelID: model.id, disposition: .unloaded)
      return .reload
    }
    if let concurrencyLimit = concurrencyLimit(for: kind), entry.inFlight >= concurrencyLimit {
      let slot = await waitForConcurrencySlot(
        modelID: model.id, timeoutNanos: remainingNanos(until: deadline))
      if slot == false {
        throw RouteError.concurrencyLimitExceeded(modelID: model.id, limit: concurrencyLimit)
      }
      return .retry
    }
    var admitted = entry
    admitted.lastUsed = Date()
    admitted.inFlight += 1
    routes[model.id] = .loaded(admitted)
    return .served(
      RoutedServer(
        server: admitted.server,
        loadID: admitted.loadID,
        backendObj: admitted.backendObjectID))
  }

  /// Join an in-progress load for `model` and admit this request to it.
  private func awaitLoading(
    loading: LoadingEntry,
    model: ModelDescriptor,
    kind: RouteKind,
    loadConfig: ModelLoadConfig,
    deadline: Date
  ) async throws -> RoutedServer {
    if loading.kind != kind {
      throw RouteError.loadConfigConflict(modelID: model.id)
    }
    log.debug(
      "router.load_wait model=\(model.id, privacy: .public) kind=\(kind.rawValue, privacy: .public) load_id=\(loading.id.uuidString, privacy: .public)"
    )
    let server = try await finishLoad(
      model: model, kind: kind, loading: loading, loadConfig: loadConfig, deadline: deadline)
    let info = loadInfo(modelID: model.id, kind: kind)
    return RoutedServer(server: server, loadID: info?.loadID, backendObj: info?.backendObjectID)
  }

  /// Make room, spawn `model`, and admit this request to it.
  private func spawnAndBegin(
    model: ModelDescriptor,
    kind: RouteKind,
    loadConfig: ModelLoadConfig,
    deadline: Date
  ) async throws -> RoutedServer {
    try await ensureHeadroom(
      modelID: model.id, needing: model.sizeBytes, loadConfig: loadConfig, kind: kind)
    let loadTask = Task {
      try await spawner(model, kind, loadConfig)
    }
    let loading = LoadingEntry(kind: kind, task: loadTask)
    routes[model.id] = .loading(loading)
    let server = try await finishLoad(
      model: model, kind: kind, loading: loading, loadConfig: loadConfig, deadline: deadline)
    let info = loadInfo(modelID: model.id, kind: kind)
    return RoutedServer(server: server, loadID: info?.loadID, backendObj: info?.backendObjectID)
  }

  public func routeEmbeddingAndBegin(
    _ model: ModelDescriptor,
    loadConfig: ModelLoadConfig? = nil
  ) async throws -> ModelServer {
    try await routeAndBegin(model, kind: .embedding, loadConfig: loadConfig)
  }

  public func routeVideoAndBegin(
    _ model: ModelDescriptor,
    loadConfig: ModelLoadConfig? = nil,
    requestID: UUID? = nil
  ) async throws -> ModelServer {
    try await routeAndBegin(model, kind: .video, loadConfig: loadConfig, requestID: requestID)
  }

  private func validateRouteKind(model: ModelDescriptor, kind: RouteKind) throws {
    switch kind {
    case .embedding:
      guard model.kind == .embedding else {
        throw RouteError.wrongKindForEmbedding(modelID: model.id)
      }
    case .chat, .video:
      guard model.kind != .embedding else {
        throw RouteError.wrongKindForChat(modelID: model.id)
      }
    }
  }

  private func loadConfigKind(_ kind: RouteKind) -> ModelKind {
    switch kind {
    case .embedding:
      return .embedding
    case .chat, .video:
      return .chat
    }
  }

  private func concurrencyLimit(for kind: RouteKind) -> Int? {
    switch kind {
    case .chat:
      return chatMaxConcurrency
    case .embedding:
      // Forward concurrency is enforced by the embedding host's job queue
      // (EmbeddingJobQueue); admitting here and queueing there keeps bulk
      // clients from seeing 429s while a forward is busy.
      return nil
    case .video:
      return nil
    }
  }

  private func pruneStoppedServers() {
    let stoppedEntries = routes.compactMap { modelID, state -> (String, LoadedEntry)? in
      guard case .loaded(let entry) = state, !entry.server.isRunning else {
        return nil
      }
      return (modelID, entry)
    }
    for (modelID, entry) in stoppedEntries {
      routes.removeValue(forKey: modelID)
      log.notice(
        "router.model_pruned model=\(modelID, privacy: .public) kind=\(entry.kind.rawValue, privacy: .public) reason=server_exited"
      )
      BackendTrace.notice(
        phase: TracePhase.Router.modelUnloaded.rawValue,
        context: TraceContext(
          modelID: modelID,
          modelKind: entry.kind,
          loadID: entry.loadID,
          backendObjectID: entry.backendObjectID
        ),
        snapshot: .current(),
        extras: ["reason": "server_exited"]
      )
      eventSink(.modelUnloaded(modelID: modelID, kind: entry.kind))
    }
  }

  public func requestDone(
    modelID: String,
    kind: SwiftLMTrace.BackendKind = .chat,
    requestID: UUID? = nil
  ) {
    guard let state = routes[modelID], case .loaded(var entry) = state, entry.kind == kind else {
      log.fault(
        """
        router.request_done_unknown_model model=\(modelID, privacy: .public) \
        kind=\(kind.rawValue, privacy: .public) \
        request_id=\(requestID?.uuidString ?? "none", privacy: .public)
        """
      )
      return
    }
    if entry.inFlight > 0 { entry.inFlight -= 1 }
    entry.lastUsed = Date()
    routes[modelID] = .loaded(entry)
    if entry.inFlight == 0, draining.contains(modelID) {
      // A victim being preempted has finished its last in-flight request, so
      // reclaim it now rather than waiting for the force-evict at the timeout.
      unload(modelID: modelID, disposition: .preempted)
    } else {
      wakeNextConcurrencyWaiter(modelID: modelID)
    }
    logRequestDone(entry: entry, requestID: requestID)
  }

  public func embeddingRequestDone(modelID: String) {
    requestDone(modelID: modelID, kind: .embedding)
  }

  public func videoRequestDone(modelID: String, requestID: UUID? = nil) {
    requestDone(modelID: modelID, kind: .video, requestID: requestID)
  }

  private func logRequestDone(entry: LoadedEntry, requestID: UUID?) {
    switch entry.kind {
    case .embedding:
      log.debug(
        "router.embedding_request_done model=\(entry.server.modelID, privacy: .public) in_flight=\(entry.inFlight, privacy: .public)"
      )
      BackendTrace.debug(
        phase: TracePhase.Router.embeddingRequestDone.rawValue,
        context: TraceContext(
          modelID: entry.server.modelID,
          modelKind: entry.kind,
          loadID: entry.loadID,
          backendObjectID: entry.backendObjectID,
          requestID: requestID
        ),
        snapshot: .current(),
        extras: ["inflight": "\(entry.inFlight)"]
      )
    case .chat, .video:
      log.notice(
        """
        router.request_done model=\(entry.server.modelID, privacy: .public) \
        kind=\(entry.kind.rawValue, privacy: .public) \
        request_id=\(requestID?.uuidString ?? "none", privacy: .public) \
        in_flight=\(entry.inFlight, privacy: .public)
        """
      )
      BackendTrace.notice(
        phase: TracePhase.Router.requestDone.rawValue,
        context: TraceContext(
          modelID: entry.server.modelID,
          modelKind: entry.kind,
          loadID: entry.loadID,
          backendObjectID: entry.backendObjectID,
          requestID: requestID
        ),
        snapshot: .current(),
        extras: ["inflight": "\(entry.inFlight)"]
      )
    }
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
  private func waitForConcurrencySlot(
    modelID: String,
    timeoutNanos: UInt64,
    priority: Int = 0
  ) async -> Bool {
    let waiterID = UUID()
    return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
      concurrencyWaiters[modelID, default: []].append(
        ConcurrencyWaiter(id: waiterID, priority: priority, continuation: continuation))
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

  // MARK: - Admission queue

  /// Remaining nanoseconds until `deadline`, clamped at zero.
  private func remainingNanos(until deadline: Date) -> UInt64 {
    UInt64(max(0, deadline.timeIntervalSinceNow) * Self.nanosecondsPerSecond)
  }

  /// Park a load that cannot be admitted yet until memory frees or the request's
  /// deadline passes. Returns `true` when woken to retry, `false` when the queue
  /// is full. Reuses the concurrency waiter's timer under a reserved key so no
  /// second timer is introduced.
  private func waitForAdmission(priority: Int, until deadline: Date) async -> Bool {
    let parked = concurrencyWaiters[Self.admissionWaiterKey]?.count ?? 0
    if parked >= Self.maxAdmissionWaiters {
      return false
    }
    return await waitForConcurrencySlot(
      modelID: Self.admissionWaiterKey,
      timeoutNanos: remainingNanos(until: deadline),
      priority: priority)
  }

  /// Wake every parked admission waiter, highest priority first and FIFO within a
  /// priority, after memory frees. Each retries its route and re-parks if it still
  /// cannot be admitted.
  private func wakeAdmissionWaiters() {
    guard let waiters = concurrencyWaiters.removeValue(forKey: Self.admissionWaiterKey),
      !waiters.isEmpty
    else {
      return
    }
    let ordered = waiters.enumerated().sorted { lhs, rhs in
      if lhs.element.priority != rhs.element.priority {
        return lhs.element.priority > rhs.element.priority
      }
      return lhs.offset < rhs.offset
    }
    for entry in ordered {
      entry.element.continuation.resume(returning: true)
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
  /// pacing, forward the level to every loaded embedding server so it can shrink
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
    let wireLevel = wireThrottleLevel(level)
    for state in routes.values {
      if case .loaded(let entry) = state, entry.kind == .embedding {
        entry.server.applyPowerThrottle(wireLevel)
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

  private func wireThrottleLevel(_ level: PowerThrottleLevel) -> WireThrottleLevel {
    switch level {
    case .none:
      return .none
    case .mild:
      return .mild
    case .hard:
      return .hard
    }
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
    draining.remove(modelID)
    guard let state = routes.removeValue(forKey: modelID) else {
      return
    }
    switch state {
    case .loaded(let entry):
      entry.server.shutdown()
      reportUnload(modelID: modelID, entry: entry, disposition: disposition)
    case .loading(let loading):
      loading.task.cancel()
      log.notice(
        "router.load_cancelled model=\(modelID, privacy: .public) kind=\(loading.kind.rawValue, privacy: .public) load_id=\(loading.id.uuidString, privacy: .public)"
      )
      eventSink(
        .modelLoadCancelled(
          modelID: modelID,
          kind: loading.kind,
          loadID: loading.id.uuidString
        ))
    }
    // Memory just freed: let parked loads retry, highest priority first.
    wakeAdmissionWaiters()
  }

  /// Log, trace, and publish the lifecycle event for a loaded model leaving the
  /// router under `disposition`. Preemption also stamps the reload cooldown.
  private func reportUnload(
    modelID: String,
    entry: LoadedEntry,
    disposition: UnloadDisposition
  ) {
    let traceContext = TraceContext(
      modelID: modelID,
      modelKind: entry.kind,
      loadID: entry.loadID,
      backendObjectID: entry.backendObjectID
    )
    let reason: String
    let event: RouterLifecycleEvent
    let tracePhase: String
    switch disposition {
    case .unloaded:
      reason = "unloaded"
      event = .modelUnloaded(modelID: modelID, kind: entry.kind)
      tracePhase = TracePhase.Router.modelUnloaded.rawValue
    case .evicted:
      reason = "evicted"
      event = .modelEvicted(modelID: modelID, kind: entry.kind)
      tracePhase = TracePhase.Router.modelEvicted.rawValue
    case .preempted:
      preemptedAt[modelID] = Date()
      reason = "preempted"
      event = .modelPreempted(modelID: modelID, kind: entry.kind)
      tracePhase = TracePhase.Router.modelEvicted.rawValue
    }
    log.notice(
      "router.model_\(reason, privacy: .public) model=\(modelID, privacy: .public) kind=\(entry.kind.rawValue, privacy: .public)"
    )
    BackendTrace.notice(
      phase: tracePhase,
      context: traceContext,
      snapshot: .current(),
      extras: ["reason": reason]
    )
    eventSink(event)
  }

  public func shutdownAll() {
    let modelIDs = Array(routes.keys)
    log.notice("router.shutdown_all count=\(modelIDs.count, privacy: .public)")
    for modelID in modelIDs {
      unload(modelID: modelID)
    }
    drainConcurrencyWaiters(modelID: Self.admissionWaiterKey)
  }

  private func finishLoad(
    model: ModelDescriptor,
    kind: RouteKind,
    loading: LoadingEntry,
    loadConfig: ModelLoadConfig,
    deadline: Date
  ) async throws -> ModelServer {
    let server: ModelServer
    do {
      server = try await loading.task.value
    } catch {
      let errorDescription = String(describing: error)
      if clearLoadingIfCurrent(modelID: model.id, loading: loading) {
        log.error(
          "router.backend_launch_failed model=\(model.id, privacy: .public) kind=\(kind.rawValue, privacy: .public) load_id=\(loading.id.uuidString, privacy: .public) err=\(errorDescription, privacy: .public)"
        )
        eventSink(
          .backendLaunchFailed(
            modelID: model.id,
            kind: kind,
            errorDescription: errorDescription
          ))
      }
      throw RouteError.backendLaunchFailed(modelID: model.id)
    }

    guard let state = routes[model.id] else {
      server.shutdown()
      log.notice(
        "router.load_discarded model=\(model.id, privacy: .public) kind=\(kind.rawValue, privacy: .public) load_id=\(loading.id.uuidString, privacy: .public) reason=unloaded"
      )
      throw RouteError.backendLaunchFailed(modelID: model.id)
    }

    switch state {
    case .loaded(var entry):
      while let concurrencyLimit = concurrencyLimit(for: kind),
        entry.inFlight >= concurrencyLimit
      {
        let slot = await waitForConcurrencySlot(
          modelID: model.id, timeoutNanos: remainingNanos(until: deadline))
        if slot == false {
          throw RouteError.concurrencyLimitExceeded(
            modelID: model.id,
            limit: concurrencyLimit
          )
        }
        guard case .loaded(let refreshed)? = routes[model.id] else {
          throw RouteError.backendLaunchFailed(modelID: model.id)
        }
        entry = refreshed
      }
      entry.lastUsed = Date()
      entry.inFlight += 1
      routes[model.id] = .loaded(entry)
      return entry.server
    case .loading(let current) where current.id == loading.id:
      var entry = LoadedEntry(
        server: server,
        kind: kind,
        loadID: loading.id,
        loadConfig: loadConfig
      )
      entry.inFlight = 1
      routes[model.id] = .loaded(entry)
      if kind == .embedding {
        server.applyPowerThrottle(wireThrottleLevel(currentThrottleLevel))
      }
      log.notice(
        "router.model_spawned model=\(model.id, privacy: .public) kind=\(kind.rawValue, privacy: .public) load_id=\(loading.id.uuidString, privacy: .public)"
      )
      BackendTrace.notice(
        phase: TracePhase.Router.modelSpawned.rawValue,
        context: TraceContext(
          modelID: model.id,
          modelKind: kind,
          loadID: entry.loadID,
          backendObjectID: entry.backendObjectID
        ),
        snapshot: .current()
      )
      eventSink(.modelSpawned(modelID: model.id, kind: kind))
      return server
    case .loading:
      server.shutdown()
      log.fault(
        "router.load_stale model=\(model.id, privacy: .public) kind=\(kind.rawValue, privacy: .public) load_id=\(loading.id.uuidString, privacy: .public)"
      )
      throw RouteError.backendLaunchFailed(modelID: model.id)
    }
  }

  private func clearLoadingIfCurrent(modelID: String, loading: LoadingEntry) -> Bool {
    guard let state = routes[modelID], case .loading(let current) = state,
      current.id == loading.id
    else {
      return false
    }
    routes.removeValue(forKey: modelID)
    return true
  }
}

private func positiveLimit(_ value: Int?) -> Int? {
  guard let value, value > 0 else {
    return nil
  }
  return value
}
