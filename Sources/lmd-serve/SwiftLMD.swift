//
//  SwiftLMD.swift
//  lmd-serve
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-04-18.
//  Copyright © 2026, all rights reserved.
//
//  lmd-serve: persistent broker daemon.
//
//  Owns SwiftLM lifecycle, the model catalog, the router/eviction
//  policy and sensor sampling (formerly swiftmon). Fan control is disabled
//  during the current moratorium.
//  Exposes an OpenAI-compatible HTTP API on port 5400 by default.
//

import AppLogger
import Foundation
import HTTPTypes
import Hummingbird
import LMDServeSupport
import SwiftLMBackend
import SwiftLMControl
import SwiftLMCore
import SwiftLMEmbed
import SwiftLMMonitor
import SwiftLMRuntime
import SwiftLMTrace

// File-scope os.Logger. `@main` mode forbids top-level expressions, so
// the `AppLogger.bootstrap` call lives inside `SwiftLMD.main()` below.
// The `log` handle itself is a constant and is safe to create at file
// scope; it will be usable immediately after bootstrap runs at startup.
private let log = AppLogger.logger(category: "Broker")
private let signposter = AppLogger.signposter()

// MARK: - Defaults

let defaultBrokerHost = "localhost"
let defaultBrokerPort = 5400
// SwiftLM is a sibling project. Override via LMD_SWIFTLM_BINARY.
let defaultSwiftLMBinary: String = {
  let home = NSHomeDirectory()
  return "\(home)/Sites/SwiftLM/.build/arm64-apple-macosx/release/SwiftLM"
}()
// Per-model spawn log. Rotated per-boot. Lives under the user's
// Application Support for the bundle so it survives repo moves.
let defaultLogPath: String = {
  let home = NSHomeDirectory()
  return "\(home)/Library/Application Support/io.goodkind.lmd/logs/lmd-serve.log"
}()

enum BrokerListenAddressError: Error, CustomStringConvertible {
  case disallowedHost(String)
  case invalidPort(String)

  var description: String {
    switch self {
    case .disallowedHost(let host):
      return "LMD_HOST must be localhost or [::1], got \(host)"
    case .invalidPort(let port):
      return "LMD_PORT must be an integer from 1 through 65535, got \(port)"
    }
  }
}

struct BrokerListenAddress {
  let host: String
  let port: Int
  let bindHost: String

  var displayAddress: String {
    "\(host):\(port)"
  }

  init(environment: [String: String]) throws {
    host = environment["LMD_HOST"] ?? defaultBrokerHost

    let rawPort = environment["LMD_PORT"] ?? "\(defaultBrokerPort)"
    guard let parsedPort = Int(rawPort), (1...65_535).contains(parsedPort) else {
      throw BrokerListenAddressError.invalidPort(rawPort)
    }
    port = parsedPort

    switch host {
    case "localhost", "[::1]":
      bindHost = "::1"
    default:
      throw BrokerListenAddressError.disallowedHost(host)
    }
  }
}

// MARK: - Shared timestamp formatter
//
// Used for serializing `last_used` timestamps in JSON API responses.
// NOT a logging helper. Use `log.*` for events.

nonisolated(unsafe) let isoFormatter: ISO8601DateFormatter = {
  let f = ISO8601DateFormatter()
  f.formatOptions = [.withInternetDateTime]
  return f
}()

// MARK: - Router event helper

/// Publish a typed router lifecycle event to the shared bus.
func publishRouterEvent(_ event: RouterLifecycleEvent) {
  Task { await EventBus.shared.publish(BrokerEvent(routerEvent: event)) }
}

// MARK: - Legacy `slog` shim
//
// Routes the broker's existing `slog("...")` call sites through the
// unified `os.Logger` at `.notice` level so operators tail via
// `log stream --subsystem io.goodkind.lmd --info`. Kept as a helper
// because `SwiftLMServer` still accepts a `(String) -> Void` sink.
//
// Messages are marked `.public` because the broker does not handle
// user prompt text through this channel. It only carries lifecycle
// traces. New first-party code writes events via `log.<level>(...)`
// with per-value privacy annotations per Rule 3.
func slog(_ message: String) {
  log.notice("\(message, privacy: .public)")
}

// MARK: - Memory headroom

/// Bytes of system memory the broker keeps free at all times. A model load is
/// admitted only when at least this much remains available afterward. Set with
/// `LMD_RESERVE_GB`, defaulting to 20 GB.
func defaultReserveBytes() -> Int64 {
  let raw = ProcessInfo.processInfo.environment["LMD_RESERVE_GB"]
  let reserveGB = Int64(raw ?? "") ?? 20
  let gigabyte: Int64 = 1_073_741_824
  return reserveGB * gigabyte
}

// MARK: - Live backend adapter

final class LiveBackend: SwiftLMBackendProtocol, @unchecked Sendable {
  let modelID: String
  let port: Int
  let sizeBytes: Int64
  var isRunning: Bool { server.isRunning }
  private let server: SwiftLMServer

  init(
    model: ModelDescriptor,
    port: Int,
    binaryPath: String,
    logPath: String?,
    loadConfig: ModelLoadConfig
  ) {
    self.modelID = model.id
    self.port = port
    self.sizeBytes = model.sizeBytes
    self.server = SwiftLMServer(
      model: model.path,
      contextSize: loadConfig.contextLength,
      config: SwiftLMServerConfig(
        binaryPath: binaryPath,
        port: port,
        logFilePath: logPath
      ),
      log: { message in slog("server[\(model.id)]: \(message)") }
    )
  }

  func launch() throws {
    try server.start()
    guard server.waitReady() else {
      server.stop()
      throw SwiftLMServerError.readyTimeout(model: modelID, seconds: 300)
    }
  }

  func shutdown() {
    server.stop()
  }
}

// MARK: - App state

final class LoadedAliasStore: @unchecked Sendable {
  private let lock = NSLock()
  private var aliases: [String: ModelDescriptor] = [:]

  func resolve(_ id: String) -> ModelDescriptor? {
    lock.lock()
    defer {
      lock.unlock()
    }
    return aliases[id]
  }

  func set(_ identifier: String?, descriptor: ModelDescriptor) {
    guard let identifier else {
      return
    }
    lock.lock()
    aliases[identifier] = descriptor
    lock.unlock()
  }

  func clear(modelID: String) {
    lock.lock()
    aliases = aliases.filter { $0.value.id != modelID }
    lock.unlock()
  }
}

/// Everything the HTTP handlers need. The router is a `ModelRouter` actor.
final class BrokerState: @unchecked Sendable {
  let catalog: ModelCatalog
  let router: ModelRouter
  let videoChatBackend: VideoChatBackend
  let modelsByID: [String: ModelDescriptor]
  let downloadCoordinator: HubDownloadCoordinator
  let aliasStore: LoadedAliasStore

  init(
    catalog: ModelCatalog,
    router: ModelRouter,
    models: [ModelDescriptor],
    aliasStore: LoadedAliasStore,
    videoChatBackend: VideoChatBackend = NotConfiguredVideoChatBackend()
  ) {
    self.catalog = catalog
    self.router = router
    self.videoChatBackend = videoChatBackend
    self.downloadCoordinator = HubDownloadCoordinator()
    self.aliasStore = aliasStore
    var map: [String: ModelDescriptor] = [:]
    for m in models {
      map[m.id] = m
      if let slug = m.slug { map[slug] = m }
      map[m.displayName] = m
      map[m.path] = m
    }
    self.modelsByID = map
  }

  func resolve(id: String) -> ModelDescriptor? {
    if let descriptor = modelsByID[id] {
      return descriptor
    }
    return aliasStore.resolve(id)
  }
}

// MARK: - OpenAI JSON schemas

struct OpenAIModelsResponse: Codable {
  let object: String
  let data: [ModelEntry]

  // swift-format-ignore: AlwaysUseLowerCamelCase
  // Field names mirror the OpenAI `/v1/models` wire format verbatim.
  struct ModelEntry: Codable {
    let id: String
    let object: String
    let created: Int
    let owned_by: String  // swiftlint:disable:this identifier_name
    let kind: String
    let capabilities: ModelCapabilities
  }
}

struct ChatCompletionRequest: Codable {
  let model: String
}

struct ErrorEnvelope: Codable {
  let error: ErrorBody
  struct ErrorBody: Codable {
    let message: String
    let type: String
    let code: String?
  }
}

/// OpenAI `model` field: prefer HF style slug when we have one.
func openAIModelId(_ m: ModelDescriptor) -> String {
  m.slug ?? m.id
}

private let bytesPerGigabyte = 1_073_741_824.0

func idleCutoff(
  for candidate: EvictionCandidate,
  defaultChat: TimeInterval,
  defaultEmbedding: TimeInterval
) -> TimeInterval {
  if let ttlSeconds = candidate.loadConfig.ttlSeconds {
    return TimeInterval(ttlSeconds)
  }
  return candidate.isEmbedding ? defaultEmbedding : defaultChat
}

func brokerLoadedSnapshot(
  state: BrokerState,
  snap: ModelRouter.Snapshot,
  reading: MemoryReading,
  reserveBytes: Int64
) -> LoadedSnapshot {
  let entries = snap.loaded.map { candidate -> LoadedSnapshot.LoadedModel in
    let descriptor = state.modelsByID[candidate.modelID]
    return LoadedSnapshot.LoadedModel(
      modelID: candidate.modelID,
      sizeGB: Double(candidate.sizeBytes) / bytesPerGigabyte,
      lastUsed: candidate.lastUsed,
      inFlightRequests: candidate.inFlightRequests,
      kind: descriptor?.kind.rawValue ?? (candidate.isEmbedding ? "embedding" : "chat"),
      identifier: candidate.loadConfig.identifier,
      contextLength: candidate.loadConfig.contextLength,
      ttlSeconds: candidate.loadConfig.ttlSeconds,
      loadConfig: candidate.loadConfig,
      capabilities: descriptor?.capabilities ?? .textOnly
    )
  }
  return LoadedSnapshot(
    allocatedGB: Double(snap.allocatedBytes) / bytesPerGigabyte,
    availableGB: Double(reading.availableBytes) / bytesPerGigabyte,
    reserveGB: Double(reserveBytes) / bytesPerGigabyte,
    models: entries
  )
}

func modelLoadConfig(for request: ModelLoadRequest, descriptor: ModelDescriptor) -> ModelLoadConfig
{
  ModelLoadConfig(
    identifier: request.identifier,
    contextLength: request.contextLength,
    evalBatchSize: request.evalBatchSize,
    flashAttention: request.flashAttention,
    offloadKVCacheToGPU: request.offloadKVCacheToGPU,
    gpu: request.gpu,
    ttlSeconds: request.ttlSeconds
  ).normalized(for: descriptor.kind)
}

func estimatedModelMemoryGB(descriptor: ModelDescriptor, loadConfig _: ModelLoadConfig) -> Double {
  Double(descriptor.sizeBytes) / bytesPerGigabyte
}

func canLoadModel(
  state: BrokerState,
  descriptor: ModelDescriptor
) async -> Bool {
  let snap = await state.router.snapshot()
  if snap.loaded.contains(where: { $0.modelID == descriptor.id }) {
    return true
  }
  return await state.router.canLoad(needing: descriptor.sizeBytes)
}

func performModelLoad(
  state: BrokerState,
  request: ModelLoadRequest
) async throws -> ModelLoadResponse {
  guard let descriptor = state.resolve(id: request.model) else {
    throw BrokerError(kind: .modelNotFound, message: "unknown model \(request.model)")
  }
  let loadConfig = modelLoadConfig(for: request, descriptor: descriptor)
  let estimateGB = estimatedModelMemoryGB(descriptor: descriptor, loadConfig: loadConfig)
  let canLoad = await canLoadModel(state: state, descriptor: descriptor)
  let instanceID = loadConfig.identifier ?? openAIModelId(descriptor)

  if request.estimateOnly {
    return ModelLoadResponse(
      type: descriptor.kind == .embedding ? "embedding" : "llm",
      instanceID: instanceID,
      loadTimeSeconds: 0,
      status: "estimated",
      canLoad: canLoad,
      estimatedTotalMemoryGB: estimateGB,
      estimatedGPUMemoryGB: estimateGB,
      loadConfig: request.echoLoadConfig ? loadConfig : nil
    )
  }

  let startedAt = Date()
  if descriptor.kind == .embedding {
    _ = try await state.router.routeEmbeddingAndBegin(descriptor, loadConfig: loadConfig)
    await state.router.embeddingRequestDone(modelID: descriptor.id)
  } else {
    _ = try await state.router.routeAndBegin(descriptor, loadConfig: loadConfig)
    await state.router.requestDone(modelID: descriptor.id)
  }
  state.aliasStore.set(loadConfig.identifier, descriptor: descriptor)
  return ModelLoadResponse(
    type: descriptor.kind == .embedding ? "embedding" : "llm",
    instanceID: instanceID,
    loadTimeSeconds: Date().timeIntervalSince(startedAt),
    status: "loaded",
    loadConfig: request.echoLoadConfig ? loadConfig : nil
  )
}

func performModelUnload(
  state: BrokerState,
  request: ModelUnloadRequest
) async throws -> ModelUnloadResponse {
  if request.all {
    let loaded = await state.router.loadedModelInfos()
    let modelIDs = Array(Set(loaded.map(\.modelID))).sorted()
    for modelID in modelIDs {
      await state.router.unload(modelID: modelID)
      state.aliasStore.clear(modelID: modelID)
    }
    return ModelUnloadResponse(status: "unloaded", modelIDs: modelIDs)
  }

  guard let key = request.model ?? request.identifier, !key.isEmpty else {
    throw BrokerError(kind: .invalidRequest, message: "missing `model`, `identifier`, or `all`")
  }
  guard let descriptor = state.resolve(id: key) else {
    throw BrokerError(kind: .modelNotFound, message: "unknown model \(key)")
  }
  await state.router.unload(modelID: descriptor.id)
  state.aliasStore.clear(modelID: descriptor.id)
  return ModelUnloadResponse(status: "unloaded", modelIDs: [descriptor.id])
}

// MARK: - Boot

@main
struct SwiftLMD {
  static func main() async throws {
    AppLogger.bootstrap(subsystem: "io.goodkind.lmd")
    slog("swiftlmd v\(SwiftLMCore.version) starting")

    // Build catalog
    let catalog = ModelCatalog(roots: ModelCatalog.defaultRoots)
    let models = catalog.allModels()
    slog("catalog: \(models.count) models discovered")
    for m in models.prefix(10) {
      let gb = Double(m.sizeBytes) / 1_073_741_824
      slog("  \(m.displayName) (\(String(format: "%.1f", gb)) GB)")
    }

    // Memory headroom and binary
    let reserveBytes = defaultReserveBytes()
    slog("memory: reserve=\(reserveBytes / 1_073_741_824) GB")

    // Watch system memory pressure. The probe reads the latest level on demand,
    // and the handler set below evicts idle models the moment memory turns
    // warning or critical.
    let pressureMonitor = MemoryPressureMonitor()
    pressureMonitor.start()
    let memoryProbe: MemoryProbe = {
      let mem = AvailableMemory.read()
      return MemoryReading(
        availableBytes: mem.availableBytes,
        underPressure: pressureMonitor.currentLevel() != .normal
      )
    }

    let binary = ProcessInfo.processInfo.environment["LMD_SWIFTLM_BINARY"] ?? defaultSwiftLMBinary
    guard FileManager.default.isExecutableFile(atPath: binary) else {
      slog("ERROR: SwiftLM binary not executable at \(binary)")
      exit(1)
    }

    // Router. `ModelRouter` writes its own structured logs directly.
    // The typed lifecycle hook only feeds the shared `EventBus` so
    // subscribers (`/swiftlmd/events`, future EventsTab) see state
    // transitions without a duplicate broker log line.
    let aliasStore = LoadedAliasStore()
    let chatMaxConcurrency =
      Int(ProcessInfo.processInfo.environment["LMD_CHAT_MAX_CONCURRENCY"] ?? "")
    let embeddingMaxConcurrency =
      Int(ProcessInfo.processInfo.environment["LMD_EMBEDDING_MAX_CONCURRENCY"] ?? "")
    let router = ModelRouter(
      reserveBytes: reserveBytes,
      memoryProbe: memoryProbe,
      spawner: { model, port, loadConfig in
        LiveBackend(
          model: model,
          port: port,
          binaryPath: binary,
          logPath: defaultLogPath,
          loadConfig: loadConfig
        )
      },
      embeddingSpawner: { model, _ in
        let backend = try EmbeddingBackendFactory.makeBackend(descriptor: model)
        try await backend.launch()
        return backend
      },
      chatMaxConcurrency: chatMaxConcurrency,
      embeddingMaxConcurrency: embeddingMaxConcurrency,
      eventSink: { event in
        switch event {
        case .modelUnloaded(let modelID, _),
          .modelEvicted(let modelID, _),
          .embeddingUnloaded(let modelID),
          .embeddingEvicted(let modelID):
          aliasStore.clear(modelID: modelID)
        default:
          break
        }
        publishRouterEvent(event)
      }
    )

    let state = BrokerState(
      catalog: catalog,
      router: router,
      models: models,
      aliasStore: aliasStore,
      videoChatBackend: InProcessVLMVideoChatBackend()
    )

    // React to memory pressure the instant the system reports it, ahead of the
    // periodic sweep below.
    pressureMonitor.setOnChange { level in
      if level != .normal {
        Task { await router.enforceHeadroom() }
      }
    }

    // Battery throttle: a wide engage/resume band so the level never flaps. It
    // engages the embedding throttle once charge falls to LMD_BATTERY_THROTTLE_PCT
    // (default 20) and holds it until charge recovers to LMD_BATTERY_RESUME_PCT
    // (default 80), letting the battery recharge a full cycle before releasing.
    // Mirrors the memory-pressure monitor above.
    let powerConfig = PowerMonitor.Config(
      engagePct: Int(ProcessInfo.processInfo.environment["LMD_BATTERY_THROTTLE_PCT"] ?? "") ?? 20,
      resumePct: Int(ProcessInfo.processInfo.environment["LMD_BATTERY_RESUME_PCT"] ?? "") ?? 80
    )
    let powerMonitor = PowerMonitor(config: powerConfig) {
      Battery.read().percent
    }
    powerMonitor.setOnChange { level in
      let throttle: PowerThrottleLevel
      switch level {
      case .none:
        throttle = .none
      case .hard:
        throttle = .hard
      }
      Task { await router.applyPowerThrottle(throttle) }
    }
    powerMonitor.start()
    _ = powerMonitor

    // XPC control surface for first-party Swift clients (lmd CLI,
    // lmd-tui). Shares `state` with the HTTP routes so both transports
    // see the same router and catalog. The listener is retained for
    // the life of the process; let the constant pin it.
    let xpcListener: XPCListener?
    if ProcessInfo.processInfo.environment["LMD_DISABLE_XPC"] == "1" {
      xpcListener = nil
      log.info("xpc.disabled reason=environment")
    } else {
      do {
        xpcListener = try startXPCControl(state: state)
      } catch let skipped as XPCListenerSkippedError {
        xpcListener = nil
        log.notice("xpc.listener_skipped reason=\(skipped.reason, privacy: .public)")
      } catch {
        xpcListener = nil
        log.error("xpc.listener_failed reason=\(String(describing: error), privacy: .public)")
      }
    }
    _ = xpcListener

    // Idle-unload loop: every 60s, unload any model whose lastUsed is older
    // than LMD_IDLE_MINUTES (default 15). Saves memory when idle.
    let idleMinutes = Int(ProcessInfo.processInfo.environment["LMD_IDLE_MINUTES"] ?? "") ?? 15
    let chatIdleCutoff = TimeInterval(idleMinutes * 60)
    let embedIdleMinutes =
      Int(ProcessInfo.processInfo.environment["LMD_EMBEDDING_IDLE_MINUTES"] ?? "") ?? 60
    let embedIdleCutoff = TimeInterval(embedIdleMinutes * 60)
    Task {
      while !Task.isCancelled {
        try? await Task.sleep(nanoseconds: 60 * 1_000_000_000)
        let snap = await router.snapshot()
        let now = Date()
        for c in snap.loaded
        where c.isIdle && !c.isEmbedding
          && now.timeIntervalSince(c.lastUsed)
            >= idleCutoff(
              for: c,
              defaultChat: chatIdleCutoff,
              defaultEmbedding: embedIdleCutoff
            )
        {
          slog(
            "idle-unload: \(c.modelID) (chat, last used \(Int(now.timeIntervalSince(c.lastUsed)))s ago)"
          )
          await router.unload(modelID: c.modelID)
        }
        for c in snap.loaded
        where c.isIdle && c.isEmbedding
          && now.timeIntervalSince(c.lastUsed)
            >= idleCutoff(
              for: c,
              defaultChat: chatIdleCutoff,
              defaultEmbedding: embedIdleCutoff
            )
        {
          slog(
            "idle-unload: \(c.modelID) (embedding, last used \(Int(now.timeIntervalSince(c.lastUsed)))s ago)"
          )
          await router.unload(modelID: c.modelID)
        }

        // Keep the reserve even when nothing has gone idle, so a slow rise in
        // memory use from other applications still triggers unloading.
        await router.enforceHeadroom()
      }
    }

    // Sensor sampler: replaces the standalone swiftmon daemon. Runs as
    // a background Task inside the broker and writes a JSONL record
    // every `LMD_SAMPLE_INTERVAL` seconds under `LMD_DATA_DIR`.
    let dataDir =
      ProcessInfo.processInfo.environment["LMD_DATA_DIR"]
      ?? "\(NSHomeDirectory())/Library/Application Support/io.goodkind.lmd"
    let sampleInterval =
      Double(ProcessInfo.processInfo.environment["LMD_SAMPLE_INTERVAL"] ?? "") ?? 15
    let sampler = SensorSampler(
      config: .init(
        baseDir: dataDir,
        intervalSeconds: sampleInterval
      ))
    sampler.start()

    // BackendTrace background ticker. Emits `phase=tick` lines once per
    // second while any backend is loaded so the trace stream has
    // time-series memory data independent of request flow.
    let traceSampler = BackendTraceSampler(router: router)
    await traceSampler.start()

    log.notice("fan_control.disabled reason=moratorium")

    // HTTP router
    let httpRouter = Router()
    registerRoutes(on: httpRouter, state: state)

    let listenAddress = try BrokerListenAddress(environment: ProcessInfo.processInfo.environment)
    slog("HTTP server starting on \(listenAddress.displayAddress)")

    let app = Application(
      router: httpRouter,
      configuration: .init(
        address: .hostname(listenAddress.bindHost, port: listenAddress.port),
        serverName: "swiftlmd/\(SwiftLMCore.version)"
      )
    )
    try await app.runService()
  }
}

// MARK: - Routes

func registerRoutes(on router: Router<BasicRequestContext>, state: BrokerState) {
  router.get("/health") { _, _ -> Response in
    let body = ByteBuffer(string: #"{"status":"ok","service":"swiftlmd"}"#)
    return Response(
      status: .ok,
      headers: [.contentType: "application/json"],
      body: .init(byteBuffer: body)
    )
  }

  router.get("/v1/models") { _, _ -> Response in
    let entries = state.modelsByID.values
      .reduce(into: [String: ModelDescriptor]()) { acc, m in acc[m.id] = m }
      .values
      .sorted { $0.displayName.lowercased() < $1.displayName.lowercased() }
      .map { m -> OpenAIModelsResponse.ModelEntry in
        OpenAIModelsResponse.ModelEntry(
          id: openAIModelId(m),
          object: "model",
          created: Int(Date().timeIntervalSince1970),
          owned_by: m.slug?.split(separator: "/").first.map(String.init) ?? "local",
          kind: m.kind.rawValue,
          capabilities: m.capabilities
        )
      }
    let response = OpenAIModelsResponse(object: "list", data: entries)
    let data = try JSONEncoder().encode(response)
    return Response(
      status: .ok,
      headers: [.contentType: "application/json"],
      body: .init(byteBuffer: ByteBuffer(data: data))
    )
  }

  router.get("/swiftlmd/loaded") { _, _ async throws -> Response in
    let snap = await state.router.snapshot()
    let reading = await state.router.memoryReading()
    let reserveBytes = await state.router.reserveBytes
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let data = try encoder.encode(
      brokerLoadedSnapshot(
        state: state, snap: snap, reading: reading, reserveBytes: reserveBytes))
    return Response(
      status: .ok,
      headers: [.contentType: "application/json"],
      body: .init(byteBuffer: ByteBuffer(data: data))
    )
  }

  router.post("/api/v1/models/load") { req, _ async throws -> Response in
    let bodyBuffer = try await req.body.collect(upTo: 1024 * 1024)
    let bodyData = Data(buffer: bodyBuffer)
    let request: ModelLoadRequest
    do {
      request = try JSONDecoder().decode(ModelLoadRequest.self, from: bodyData)
    } catch {
      return errorResponse(
        status: .badRequest,
        message: "invalid load request",
        type: "invalid_request_error"
      )
    }
    do {
      let response = try await performModelLoad(state: state, request: request)
      let data = try JSONEncoder().encode(response)
      return Response(
        status: request.estimateOnly ? .ok : .accepted,
        headers: [.contentType: "application/json"],
        body: .init(byteBuffer: ByteBuffer(data: data))
      )
    } catch let error as BrokerError {
      let status: HTTPResponse.Status = error.kind == .modelNotFound ? .notFound : .badRequest
      return errorResponse(status: status, message: error.message, type: error.kind.rawValue)
    } catch {
      return errorResponse(
        status: .serviceUnavailable,
        message: "load failed: \(error)",
        type: "load_failed"
      )
    }
  }

  router.post("/api/v1/models/unload") { req, _ async throws -> Response in
    let bodyBuffer = try await req.body.collect(upTo: 1024 * 1024)
    let bodyData = Data(buffer: bodyBuffer)
    let request: ModelUnloadRequest
    do {
      request = try JSONDecoder().decode(ModelUnloadRequest.self, from: bodyData)
    } catch {
      return errorResponse(
        status: .badRequest,
        message: "invalid unload request",
        type: "invalid_request_error"
      )
    }
    do {
      let response = try await performModelUnload(state: state, request: request)
      let data = try JSONEncoder().encode(response)
      return Response(
        status: .ok,
        headers: [.contentType: "application/json"],
        body: .init(byteBuffer: ByteBuffer(data: data))
      )
    } catch let error as BrokerError {
      let status: HTTPResponse.Status = error.kind == .modelNotFound ? .notFound : .badRequest
      return errorResponse(status: status, message: error.message, type: error.kind.rawValue)
    }
  }

  router.post("/v1/embeddings") { req, _ async throws -> Response in
    try await handleEmbeddings(req: req, state: state)
  }

  // /v1/chat/completions and /v1/completions: parse, JIT-route, proxy.
  router.post("/v1/chat/completions") { req, _ async throws -> Response in
    try await handleChat(endpoint: .chatCompletions, req: req, state: state)
  }
  router.post("/v1/completions") { req, _ async throws -> Response in
    try await handleChat(endpoint: .completions, req: req, state: state)
  }

  // GET /swiftlmd/events  Server-Sent-Events stream of broker lifecycle.
  //   Subscribers receive every future event plus the last 32 buffered
  //   events as backfill so a reconnecting TUI can catch up.
  router.get("/swiftlmd/events") { _, _ -> Response in
    let body = ResponseBody(asyncSequence: BrokerEventsSequence(backfillCount: 32))
    return Response(
      status: .ok,
      headers: [
        .contentType: "text/event-stream",
        .cacheControl: "no-cache",
      ],
      body: body
    )
  }

  // swiftlmd-specific control plane.
  //
  // POST /swiftlmd/preload  body {"model": "<id>"}
  //   Spawns the backend and warms it without sending a chat request.
  //   Returns 202 when ready.
  router.post("/swiftlmd/preload") { req, _ async throws -> Response in
    let bodyBuffer = try await req.body.collect(upTo: 1024 * 1024)
    let bodyData = Data(buffer: bodyBuffer)
    let request: ModelLoadRequest
    do {
      request = try JSONDecoder().decode(ModelLoadRequest.self, from: bodyData)
    } catch {
      return errorResponse(
        status: .badRequest, message: "missing `model`", type: "invalid_request_error")
    }
    do {
      let response = try await performModelLoad(state: state, request: request)
      let data = try JSONEncoder().encode(response)
      return Response(
        status: request.estimateOnly ? .ok : .accepted,
        headers: [.contentType: "application/json"],
        body: .init(byteBuffer: ByteBuffer(data: data))
      )
    } catch let error as BrokerError {
      let status: HTTPResponse.Status = error.kind == .modelNotFound ? .notFound : .badRequest
      return errorResponse(status: status, message: error.message, type: error.kind.rawValue)
    } catch {
      return errorResponse(
        status: .serviceUnavailable,
        message: "preload failed: \(error)",
        type: "preload_failed"
      )
    }
  }

  // POST /swiftlmd/unload  body {"model": "<id>"}
  //   Force-unloads a model even if it was loaded moments ago.
  router.post("/swiftlmd/unload") { req, _ async throws -> Response in
    let bodyBuffer = try await req.body.collect(upTo: 1024 * 1024)
    let bodyData = Data(buffer: bodyBuffer)
    let request: ModelUnloadRequest
    do {
      request = try JSONDecoder().decode(ModelUnloadRequest.self, from: bodyData)
    } catch {
      return errorResponse(
        status: .badRequest, message: "missing `model`", type: "invalid_request_error")
    }
    do {
      let response = try await performModelUnload(state: state, request: request)
      let data = try JSONEncoder().encode(response)
      return Response(
        status: .ok,
        headers: [.contentType: "application/json"],
        body: .init(byteBuffer: ByteBuffer(data: data))
      )
    } catch let error as BrokerError {
      let status: HTTPResponse.Status = error.kind == .modelNotFound ? .notFound : .badRequest
      return errorResponse(status: status, message: error.message, type: error.kind.rawValue)
    }
  }
}

// MARK: - Embeddings

func handleEmbeddings(req: Request, state: BrokerState) async throws -> Response {
  let bodyBuffer = try await req.body.collect(upTo: 32 * 1024 * 1024)
  let bodyData = Data(buffer: bodyBuffer)
  guard let json = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any],
    let modelField = json["model"] as? String
  else {
    return errorResponse(
      status: .badRequest, message: "missing `model` field", type: "invalid_request_error")
  }
  if (json["stream"] as? Bool) == true {
    return errorResponse(
      status: .badRequest,
      message: "stream is not supported for embeddings",
      type: "invalid_request_error"
    )
  }
  if let fmt = json["encoding_format"] as? String, fmt != "float" {
    return errorResponse(
      status: .badRequest,
      message: "only encoding_format float is supported",
      type: "invalid_request_error"
    )
  }

  let inputs: [String]
  if let s = json["input"] as? String {
    inputs = [s]
  } else if let arr = json["input"] as? [String] {
    inputs = arr
  } else {
    return errorResponse(
      status: .badRequest,
      message: "`input` must be a string or array of strings",
      type: "invalid_request_error"
    )
  }

  guard let descriptor = state.resolve(id: modelField) else {
    return errorResponse(
      status: .notFound,
      message: "unknown model \(modelField)",
      type: "model_not_found",
      code: "model_not_found"
    )
  }
  guard descriptor.kind == .embedding else {
    return errorResponse(
      status: .badRequest,
      message: "model is not an embedding model; use /v1/chat/completions",
      type: "invalid_request_error"
    )
  }

  let requestID = UUID()
  let requestIDString = requestID.uuidString
  let receivedContext = TraceContext(
    modelID: descriptor.id,
    modelKind: .embedding,
    requestID: requestID
  )
  BackendTrace.notice(
    phase: TracePhase.Broker.requestReceived.rawValue,
    context: receivedContext,
    snapshot: .current(),
    extras: ["transport": "http", "input_count": "\(inputs.count)"]
  )
  log.notice(
    "embedding.request_started request_id=\(requestIDString, privacy: .public) transport=http model=\(descriptor.id, privacy: .public) count=\(inputs.count, privacy: .public)"
  )
  BackendTrace.notice(
    phase: TracePhase.Broker.requestStarted.rawValue,
    context: receivedContext,
    snapshot: .current(),
    extras: ["transport": "http", "input_count": "\(inputs.count)"]
  )

  let backend: EmbeddingBackendProtocol
  do {
    backend = try await state.router.routeEmbeddingAndBegin(descriptor)
  } catch let err as ModelRouter.RouteError {
    log.error(
      "embedding.request_failed request_id=\(requestIDString, privacy: .public) transport=http model=\(descriptor.id, privacy: .public) count=\(inputs.count, privacy: .public) stage=route err=\(String(describing: err), privacy: .public)"
    )
    BackendTrace.notice(
      phase: TracePhase.Broker.requestFailed.rawValue,
      context: receivedContext,
      snapshot: .current(),
      extras: [
        "transport": "http",
        "stage": "route",
        "error": String(describing: err),
      ]
    )
    switch err {
    case .insufficientHeadroom:
      return errorResponse(
        status: .serviceUnavailable,
        message: "not enough free memory to load embedding model while keeping the reserve",
        type: "capacity_exceeded"
      )
    case .backendLaunchFailed:
      return errorResponse(
        status: .serviceUnavailable,
        message: "failed to load embedding model",
        type: "launch_failed"
      )
    case .concurrencyLimitExceeded(_, let limit):
      return errorResponse(
        status: .tooManyRequests,
        message: "embedding concurrency limit reached (\(limit))",
        type: "capacity_exceeded"
      )
    case .loadConfigConflict:
      return errorResponse(
        status: .conflict,
        message: "embedding model is busy with a different load configuration",
        type: "load_config_conflict"
      )
    case .unsupportedEmbeddingBackend(_, let reason):
      return errorResponse(
        status: .badRequest,
        message: reason,
        type: "unsupported_embedding_backend"
      )
    case .embeddingSpawnerMissing:
      return errorResponse(
        status: .serviceUnavailable,
        message: "embedding support is not configured",
        type: "not_configured"
      )
    case .noFreePort:
      return errorResponse(
        status: .serviceUnavailable,
        message: "no free port in pool",
        type: "capacity_exceeded"
      )
    case .wrongKindForChat:
      return errorResponse(
        status: .badRequest,
        message: "model is an embedding model; use POST /v1/embeddings",
        type: "invalid_request_error"
      )
    case .wrongKindForEmbedding:
      return errorResponse(
        status: .badRequest,
        message: "model is not an embedding model",
        type: "invalid_request_error"
      )
    }
  }

  let routerInfo = await state.router.embeddingLoadInfo(modelID: descriptor.id)
  let routedContext = TraceContext(
    modelID: descriptor.id,
    modelKind: .embedding,
    loadID: routerInfo?.loadID,
    backendObjectID: routerInfo?.backendObjectID,
    requestID: requestID
  )
  BackendTrace.notice(
    phase: TracePhase.Broker.requestRouted.rawValue,
    context: routedContext,
    snapshot: .current(),
    extras: ["transport": "http"]
  )
  let requestDoneToken = BackendLifetimeToken {
    await state.router.embeddingRequestDone(modelID: descriptor.id)
  }

  let vectors: [[Float]]
  do {
    vectors = try await TraceTaskLocal.$requestID.withValue(requestID) {
      try await TraceTaskLocal.$loadID.withValue(routerInfo?.loadID) {
        try await TraceTaskLocal.$backendObjectID.withValue(routerInfo?.backendObjectID) {
          try await backend.embed(inputs: inputs)
        }
      }
    }
  } catch {
    await requestDoneToken.finish()
    log.error(
      "embedding.request_failed request_id=\(requestIDString, privacy: .public) transport=http model=\(descriptor.id, privacy: .public) count=\(inputs.count, privacy: .public) stage=embed err=\(String(describing: error), privacy: .public)"
    )
    BackendTrace.notice(
      phase: TracePhase.Broker.requestFailed.rawValue,
      context: routedContext,
      snapshot: .current(),
      extras: [
        "transport": "http",
        "stage": "embed",
        "error": String(describing: error),
      ]
    )
    return errorResponse(
      status: .serviceUnavailable,
      message: "embedding failed: \(error)",
      type: "embedding_failed"
    )
  }
  // Battery throttle: pace before releasing the slot so consecutive embeds leave
  // a GPU-idle gap. The sleep runs in this handler task, not the router actor, so
  // chat and other routing are never blocked while a request is paced.
  let embeddingPacingNanos = await state.router.embeddingPacing()
  if embeddingPacingNanos > 0 {
    try? await Task.sleep(nanoseconds: embeddingPacingNanos)
  }
  await requestDoneToken.finish()
  BackendTrace.notice(
    phase: TracePhase.Broker.requestDoneAck.rawValue,
    context: routedContext,
    snapshot: .current(),
    extras: ["transport": "http", "vectors": "\(vectors.count)"]
  )
  log.notice(
    "embedding.request_completed request_id=\(requestIDString, privacy: .public) transport=http model=\(descriptor.id, privacy: .public) count=\(inputs.count, privacy: .public) vectors=\(vectors.count, privacy: .public)"
  )
  BackendTrace.notice(
    phase: TracePhase.Broker.requestCompleted.rawValue,
    context: routedContext,
    snapshot: .current(),
    extras: ["transport": "http", "vectors": "\(vectors.count)"]
  )

  struct EmbRow: Codable {
    let object: String
    let embedding: [Float]
    let index: Int
  }
  struct EmbOut: Codable {
    let object: String
    let data: [EmbRow]
    let model: String
    // swift-format-ignore: AlwaysUseLowerCamelCase
    // Field names mirror the OpenAI embedding usage wire format verbatim.
    struct Usage: Codable {
      let prompt_tokens: Int
      let total_tokens: Int
    }
    let usage: Usage
  }
  let rows = vectors.enumerated().map { i, vec in
    EmbRow(object: "embedding", embedding: vec, index: i)
  }
  let out = EmbOut(
    object: "list",
    data: rows,
    model: openAIModelId(descriptor),
    usage: .init(prompt_tokens: 0, total_tokens: 0)
  )
  let data = try JSONEncoder().encode(out)
  BackendTrace.notice(
    phase: TracePhase.Broker.requestResponseSent.rawValue,
    context: routedContext,
    snapshot: .current(),
    extras: ["transport": "http", "bytes": "\(data.count)"]
  )
  return Response(
    status: .ok,
    headers: [.contentType: "application/json"],
    body: .init(byteBuffer: ByteBuffer(data: data))
  )
}

// MARK: - Chat ingress

private struct ChatProxyLogContext: Sendable {
  let requestID: UUID
  let clientRequestID: String?
  let startedAt: Date
  let endpointPath: String
  let wantsStream: Bool
  let requestBodyBytes: Int
  let modelID: String
  let modelPath: String

  var requestIDString: String {
    clientRequestID ?? requestID.uuidString
  }
}

private struct SafeErrorFields: Sendable {
  let type: String
  let message: String
}

private func safeErrorFields(_ error: Error) -> SafeErrorFields {
  if let urlError = error as? URLError {
    return SafeErrorFields(
      type: "URLError.\(urlError.code.rawValue)",
      message: urlError.localizedDescription
    )
  }
  return SafeErrorFields(
    type: String(reflecting: Swift.type(of: error)),
    message: String(describing: error)
  )
}

private func estimatedPromptCharacters(in value: Any) -> Int {
  switch value {
  case let string as String:
    return string.count
  case let array as [Any]:
    return array.reduce(0) { partial, item in
      partial + estimatedPromptCharacters(in: item)
    }
  case let dictionary as [String: Any]:
    if let type = dictionary["type"] as? String,
      type == "image_url" || type == "input_audio"
    {
      return 0
    }
    return dictionary.reduce(0) { partial, item in
      partial + estimatedPromptCharacters(in: item.value)
    }
  default:
    return 0
  }
}

private func estimatedPromptTokens(for request: PreparedChatRequest) -> Int {
  let characters: Int
  switch request.endpoint {
  case .chatCompletions:
    characters = estimatedPromptCharacters(in: request.json["messages"] ?? [])
  case .completions:
    characters = estimatedPromptCharacters(in: request.json["prompt"] ?? "")
  }
  return max(1, (characters / 4) + 32)
}

private func promptCacheMaxTokens() -> Int? {
  guard let value = Int(ProcessInfo.processInfo.environment["LMD_PROMPT_CACHE_MAX_TOKENS"] ?? ""),
    value > 0
  else {
    if !promptCacheEnabled() {
      return 8192
    }
    return nil
  }
  return value
}

private func promptCacheEnabled() -> Bool {
  switch (ProcessInfo.processInfo.environment["LMD_PROMPT_CACHE_ENABLED"] ?? "").lowercased() {
  case "0", "false", "no", "off":
    return false
  default:
    return true
  }
}

private func chatRequestBudgetError(
  prepared: PreparedChatRequest,
  loadConfig: ModelLoadConfig
) -> String? {
  let estimatedTokens = estimatedPromptTokens(for: prepared)
  if let contextLength = loadConfig.contextLength, estimatedTokens > contextLength {
    return "estimated prompt tokens \(estimatedTokens) exceed context_length \(contextLength)"
  }
  if let promptCacheLimit = promptCacheMaxTokens(), estimatedTokens > promptCacheLimit {
    return
      "estimated prompt tokens \(estimatedTokens) exceed prompt cache limit \(promptCacheLimit)"
  }
  return nil
}

private func elapsedMilliseconds(since start: Date) -> Int {
  max(0, Int((Date().timeIntervalSince(start) * 1000).rounded()))
}

private func lmReviewRequestID(from req: Request) -> String? {
  guard let fieldName = HTTPField.Name("X-LM-Review-Request-ID") else {
    return nil
  }
  guard let rawValue = req.headers[fieldName]?.trimmingCharacters(in: .whitespacesAndNewlines)
  else {
    return nil
  }
  guard !rawValue.isEmpty else {
    return nil
  }
  return String(rawValue.prefix(128))
}

private func chatTraceExtras(
  for context: ChatProxyLogContext,
  additional: [String: String] = [:]
) -> [String: String] {
  var extras = [
    "transport": "http",
    "endpoint": context.endpointPath,
    "stream": "\(context.wantsStream)",
    "request_bytes": "\(context.requestBodyBytes)",
    "model_path": context.modelPath,
    "client_request_id": context.clientRequestID ?? "none",
  ]
  for (key, value) in additional {
    extras[key] = value
  }
  return extras
}

private func logChatParseFailure(
  requestID: UUID,
  clientRequestID: String?,
  startedAt: Date,
  endpoint: OpenAIChatEndpoint,
  requestBodyBytes: Int,
  errorType: String,
  errorMessage: String
) {
  log.error(
    """
    chat.request_failed request_id=\(clientRequestID ?? requestID.uuidString, privacy: .public) \
    client_request_id=\(clientRequestID ?? "none", privacy: .public) \
    endpoint=\(endpoint.path, privacy: .public) stream=unknown model=unknown \
    model_path=unknown upstream_port=none upstream_path=\(endpoint.path, privacy: .public) \
    request_bytes=\(requestBodyBytes, privacy: .public) status_code=400 \
    duration_ms=\(elapsedMilliseconds(since: startedAt), privacy: .public) \
    stage=parse error_type=\(errorType, privacy: .public) error_message=\(errorMessage, privacy: .public)
    """
  )
}

private func logChatRequestReceived(_ context: ChatProxyLogContext) {
  log.notice(
    """
    chat.request_received request_id=\(context.requestIDString, privacy: .public) \
    client_request_id=\(context.clientRequestID ?? "none", privacy: .public) \
    endpoint=\(context.endpointPath, privacy: .public) stream=\(context.wantsStream, privacy: .public) \
    model=\(context.modelID, privacy: .public) model_path=\(context.modelPath, privacy: .public) \
    request_bytes=\(context.requestBodyBytes, privacy: .public)
    """
  )
}

private func logChatRequestStarted(_ context: ChatProxyLogContext) {
  log.notice(
    """
    chat.request_started request_id=\(context.requestIDString, privacy: .public) \
    client_request_id=\(context.clientRequestID ?? "none", privacy: .public) \
    endpoint=\(context.endpointPath, privacy: .public) stream=\(context.wantsStream, privacy: .public) \
    model=\(context.modelID, privacy: .public) model_path=\(context.modelPath, privacy: .public) \
    request_bytes=\(context.requestBodyBytes, privacy: .public)
    """
  )
}

private func logChatRequestRouted(
  _ context: ChatProxyLogContext,
  upstreamPort: Int,
  upstreamPath: String
) {
  log.notice(
    """
    chat.request_routed request_id=\(context.requestIDString, privacy: .public) \
    client_request_id=\(context.clientRequestID ?? "none", privacy: .public) \
    endpoint=\(context.endpointPath, privacy: .public) stream=\(context.wantsStream, privacy: .public) \
    model=\(context.modelID, privacy: .public) model_path=\(context.modelPath, privacy: .public) \
    upstream_port=\(upstreamPort, privacy: .public) upstream_path=\(upstreamPath, privacy: .public) \
    request_bytes=\(context.requestBodyBytes, privacy: .public)
    """
  )
}

private func logChatRequestDoneAck(
  _ context: ChatProxyLogContext,
  upstreamPort: Int,
  upstreamPath: String
) {
  log.notice(
    """
    chat.request_done_ack request_id=\(context.requestIDString, privacy: .public) \
    client_request_id=\(context.clientRequestID ?? "none", privacy: .public) \
    endpoint=\(context.endpointPath, privacy: .public) stream=\(context.wantsStream, privacy: .public) \
    model=\(context.modelID, privacy: .public) model_path=\(context.modelPath, privacy: .public) \
    upstream_port=\(upstreamPort, privacy: .public) upstream_path=\(upstreamPath, privacy: .public) \
    duration_ms=\(elapsedMilliseconds(since: context.startedAt), privacy: .public)
    """
  )
}

private func logChatRequestCompleted(
  _ context: ChatProxyLogContext,
  upstreamPort: Int,
  upstreamPath: String,
  statusCode: Int,
  responseBodyBytes: Int?
) {
  let responseBytes = responseBodyBytes.map(String.init) ?? "stream"
  log.notice(
    """
    chat.request_completed request_id=\(context.requestIDString, privacy: .public) \
    client_request_id=\(context.clientRequestID ?? "none", privacy: .public) \
    endpoint=\(context.endpointPath, privacy: .public) stream=\(context.wantsStream, privacy: .public) \
    model=\(context.modelID, privacy: .public) model_path=\(context.modelPath, privacy: .public) \
    upstream_port=\(upstreamPort, privacy: .public) upstream_path=\(upstreamPath, privacy: .public) \
    status_code=\(statusCode, privacy: .public) request_bytes=\(context.requestBodyBytes, privacy: .public) \
    response_bytes=\(responseBytes, privacy: .public) \
    duration_ms=\(elapsedMilliseconds(since: context.startedAt), privacy: .public)
    """
  )
}

private func logChatRequestFailed(
  _ context: ChatProxyLogContext,
  upstreamPort: Int?,
  upstreamPath: String,
  statusCode: Int?,
  stage: String,
  errorType: String,
  errorMessage: String
) {
  log.error(
    """
    chat.request_failed request_id=\(context.requestIDString, privacy: .public) \
    client_request_id=\(context.clientRequestID ?? "none", privacy: .public) \
    endpoint=\(context.endpointPath, privacy: .public) stream=\(context.wantsStream, privacy: .public) \
    model=\(context.modelID, privacy: .public) model_path=\(context.modelPath, privacy: .public) \
    upstream_port=\(upstreamPort.map(String.init) ?? "none", privacy: .public) \
    upstream_path=\(upstreamPath, privacy: .public) \
    status_code=\(statusCode.map(String.init) ?? "none", privacy: .public) \
    request_bytes=\(context.requestBodyBytes, privacy: .public) \
    duration_ms=\(elapsedMilliseconds(since: context.startedAt), privacy: .public) \
    stage=\(stage, privacy: .public) error_type=\(errorType, privacy: .public) \
    error_message=\(errorMessage, privacy: .public)
    """
  )
}

func handleChat(
  endpoint: OpenAIChatEndpoint,
  req: Request,
  state: BrokerState
) async throws -> Response {
  let requestID = UUID()
  let clientRequestID = lmReviewRequestID(from: req)
  let startedAt = Date()
  let bodyBuffer = try await req.body.collect(upTo: 100 * 1024 * 1024)
  var bodyData = Data(buffer: bodyBuffer)

  let ingress: ParsedChatIngress
  do {
    ingress = try parseChatIngress(endpoint: endpoint, bodyData: bodyData)
  } catch let error as ChatIngressError {
    logChatParseFailure(
      requestID: requestID,
      clientRequestID: clientRequestID,
      startedAt: startedAt,
      endpoint: endpoint,
      requestBodyBytes: bodyData.count,
      errorType: "invalid_request_error",
      errorMessage: error.description
    )
    return renderBackendChatResult(
      backendErrorResult(
        statusCode: 400,
        message: error.description,
        type: "invalid_request_error"
      ))
  } catch {
    logChatParseFailure(
      requestID: requestID,
      clientRequestID: clientRequestID,
      startedAt: startedAt,
      endpoint: endpoint,
      requestBodyBytes: bodyData.count,
      errorType: "invalid_request_error",
      errorMessage: "missing `model` field"
    )
    return renderBackendChatResult(
      backendErrorResult(
        statusCode: 400,
        message: "missing `model` field",
        type: "invalid_request_error"
      ))
  }

  // JSON enforcement middleware. Local SwiftLM does not implement
  // grammar-constrained decoding, so `response_format` is otherwise
  // silently ignored. We inject a system message instructing the model to
  // emit JSON; combined with the already-reliable Qwen coder family this
  // lifts parse rate from roughly 50% to nearly 100% in practice.
  var json = ingress.json
  if let rewritten = injectJSONInstructionIfNeeded(&json) {
    bodyData = rewritten
  }

  guard let descriptor = state.resolve(id: ingress.modelID) else {
    let missingContext = ChatProxyLogContext(
      requestID: requestID,
      clientRequestID: clientRequestID,
      startedAt: startedAt,
      endpointPath: endpoint.path,
      wantsStream: ingress.wantsStream,
      requestBodyBytes: bodyData.count,
      modelID: ingress.modelID,
      modelPath: "unknown"
    )
    logChatRequestReceived(missingContext)
    logChatRequestFailed(
      missingContext,
      upstreamPort: nil,
      upstreamPath: endpoint.path,
      statusCode: 404,
      stage: "resolve",
      errorType: "model_not_found",
      errorMessage: "model not found"
    )
    return renderBackendChatResult(
      backendErrorResult(
        statusCode: 404,
        message: "model not found: \(ingress.modelID). try GET /v1/models",
        type: "model_not_found",
        code: "model_not_found"
      ))
  }

  let logContext = ChatProxyLogContext(
    requestID: requestID,
    clientRequestID: clientRequestID,
    startedAt: startedAt,
    endpointPath: endpoint.path,
    wantsStream: ingress.wantsStream,
    requestBodyBytes: bodyData.count,
    modelID: descriptor.id,
    modelPath: descriptor.path
  )
  let receivedTraceContext = TraceContext(
    modelID: descriptor.id,
    modelKind: .chat,
    requestID: requestID
  )
  logChatRequestReceived(logContext)
  BackendTrace.notice(
    phase: TracePhase.Broker.requestReceived.rawValue,
    context: receivedTraceContext,
    snapshot: .current(),
    extras: chatTraceExtras(for: logContext)
  )

  let prepared = prepareChatRequest(
    ingress: ingress,
    bodyData: bodyData,
    json: json,
    model: descriptor
  )
  let result: BackendChatResult
  switch dispatchChatRequest(prepared) {
  case .swiftLMProxy:
    result = try await swiftLMProxyResult(request: prepared, state: state, logContext: logContext)
  case .videoBackend(let videoRequest):
    do {
      result = try await state.videoChatBackend.complete(videoRequest)
    } catch VideoChatBackendError.notConfigured {
      result = backendErrorResult(
        statusCode: 503,
        message: "video chat backend is not configured",
        type: "not_configured",
        code: "not_configured"
      )
    } catch let backendError as VideoChatBackendError {
      switch backendError {
      case .modelMissingVideoSamplingFPS:
        result = backendErrorResult(
          statusCode: 503,
          message: backendError.description,
          type: "model_missing_video_sampling_fps",
          code: "model_missing_video_sampling_fps"
        )
      case .notConfigured:
        result = backendErrorResult(
          statusCode: 503,
          message: backendError.description,
          type: "video_backend_failed"
        )
      }
    } catch let error as VideoChatRequestBuildError {
      result = backendErrorResult(
        statusCode: 400,
        message: error.description,
        type: "invalid_request_error"
      )
    } catch {
      result = backendErrorResult(
        statusCode: 503,
        message: "video chat backend failed: \(error)",
        type: "video_backend_failed"
      )
    }
  case .failure(let failure):
    logChatRequestFailed(
      logContext,
      upstreamPort: nil,
      upstreamPath: endpoint.path,
      statusCode: 400,
      stage: "dispatch",
      errorType: "invalid_request_error",
      errorMessage: failure.description
    )
    BackendTrace.notice(
      phase: TracePhase.Broker.requestFailed.rawValue,
      context: receivedTraceContext,
      snapshot: .current(),
      extras: chatTraceExtras(
        for: logContext,
        additional: [
          "stage": "dispatch",
          "status_code": "400",
          "error_type": "invalid_request_error",
        ])
    )
    result = backendErrorResult(
      statusCode: 400,
      message: failure.description,
      type: "invalid_request_error"
    )
  }
  let canonical = canonicalizeBackendChatResult(result, requestedModelID: ingress.modelID)
  return renderBackendChatResult(canonical)
}

private func swiftLMProxyResult(
  request prepared: PreparedChatRequest,
  state: BrokerState,
  logContext: ChatProxyLogContext
) async throws -> BackendChatResult {
  let signpostState = signposter.beginInterval(
    "chat.proxy",
    id: signposter.makeSignpostID(),
    "request_id=\(logContext.requestIDString, privacy: .public) model=\(logContext.modelID, privacy: .public)"
  )
  defer { signposter.endInterval("chat.proxy", signpostState) }
  let receivedContext = TraceContext(
    modelID: prepared.model.id,
    modelKind: .chat,
    requestID: logContext.requestID
  )
  logChatRequestStarted(logContext)
  BackendTrace.notice(
    phase: TracePhase.Broker.requestStarted.rawValue,
    context: receivedContext,
    snapshot: .current(),
    extras: chatTraceExtras(for: logContext)
  )

  let backend: SwiftLMBackendProtocol
  do {
    backend = try await state.router.routeAndBegin(prepared.model, requestID: logContext.requestID)
  } catch let err as ModelRouter.RouteError {
    let statusCode: Int
    let errorType: String
    let errorMessage: String
    let result: BackendChatResult
    switch err {
    case .insufficientHeadroom:
      statusCode = 503
      errorType = "capacity_exceeded"
      errorMessage =
        "not enough free memory to load \(prepared.model.displayName) while keeping the reserve"
      result = backendErrorResult(
        statusCode: 503,
        message: errorMessage,
        type: "capacity_exceeded"
      )
    case .noFreePort:
      statusCode = 503
      errorType = "capacity_exceeded"
      errorMessage = "no free port in pool"
      result = backendErrorResult(
        statusCode: 503,
        message: errorMessage,
        type: "capacity_exceeded"
      )
    case .backendLaunchFailed:
      statusCode = 503
      errorType = "launch_failed"
      errorMessage = "failed to launch model \(prepared.model.displayName)"
      result = backendErrorResult(
        statusCode: 503,
        message: errorMessage,
        type: "launch_failed"
      )
    case .concurrencyLimitExceeded(_, let limit):
      statusCode = 429
      errorType = "capacity_exceeded"
      errorMessage = "chat concurrency limit reached (\(limit))"
      result = backendErrorResult(
        statusCode: statusCode,
        message: errorMessage,
        type: errorType
      )
    case .loadConfigConflict:
      statusCode = 409
      errorType = "load_config_conflict"
      errorMessage = "model is busy with a different load configuration"
      result = backendErrorResult(
        statusCode: statusCode,
        message: errorMessage,
        type: errorType
      )
    case .unsupportedEmbeddingBackend:
      statusCode = 500
      errorType = "internal_error"
      errorMessage = "router configuration error"
      result = backendErrorResult(
        statusCode: 500,
        message: errorMessage,
        type: "internal_error"
      )
    case .wrongKindForChat:
      statusCode = 400
      errorType = "invalid_request_error"
      errorMessage = "model is an embedding model; use POST /v1/embeddings"
      result = backendErrorResult(
        statusCode: 400,
        message: errorMessage,
        type: "invalid_request_error"
      )
    case .wrongKindForEmbedding, .embeddingSpawnerMissing:
      statusCode = 500
      errorType = "internal_error"
      errorMessage = "router configuration error"
      result = backendErrorResult(
        statusCode: 500,
        message: errorMessage,
        type: "internal_error"
      )
    }
    logChatRequestFailed(
      logContext,
      upstreamPort: nil,
      upstreamPath: prepared.endpoint.path,
      statusCode: statusCode,
      stage: "route",
      errorType: errorType,
      errorMessage: "\(errorMessage): \(err)"
    )
    BackendTrace.notice(
      phase: TracePhase.Broker.requestFailed.rawValue,
      context: receivedContext,
      snapshot: .current(),
      extras: chatTraceExtras(
        for: logContext,
        additional: [
          "stage": "route",
          "status_code": "\(statusCode)",
          "error_type": errorType,
        ])
    )
    return result
  }

  // swiftlint:disable:next force_unwrapping
  let upstreamURL = URL(string: "http://localhost:\(backend.port)\(prepared.endpoint.path)")!
  let routerInfo = await state.router.chatLoadInfo(modelID: prepared.model.id)
  let routedContext = TraceContext(
    modelID: prepared.model.id,
    modelKind: .chat,
    loadID: routerInfo?.loadID,
    backendObjectID: routerInfo?.backendObjectID,
    requestID: logContext.requestID
  )
  let requestDoneToken = BackendLifetimeToken {
    await state.router.requestDone(modelID: prepared.model.id, requestID: logContext.requestID)
    logChatRequestDoneAck(
      logContext, upstreamPort: backend.port, upstreamPath: prepared.endpoint.path)
    BackendTrace.notice(
      phase: TracePhase.Broker.requestDoneAck.rawValue,
      context: routedContext,
      snapshot: .current(),
      extras: chatTraceExtras(
        for: logContext,
        additional: [
          "upstream_port": "\(backend.port)",
          "upstream_path": prepared.endpoint.path,
        ])
    )
  }
  let loadedInfo = await state.router.loadedModelInfos().first {
    $0.modelID == prepared.model.id && $0.kind == .chat
  }
  let effectiveLoadConfig = loadedInfo?.loadConfig ?? .default
  if let budgetError = chatRequestBudgetError(prepared: prepared, loadConfig: effectiveLoadConfig) {
    await requestDoneToken.finish()
    logChatRequestFailed(
      logContext,
      upstreamPort: backend.port,
      upstreamPath: prepared.endpoint.path,
      statusCode: 413,
      stage: "budget",
      errorType: "context_length_exceeded",
      errorMessage: budgetError
    )
    BackendTrace.notice(
      phase: TracePhase.Broker.requestFailed.rawValue,
      context: routedContext,
      snapshot: .current(),
      extras: chatTraceExtras(
        for: logContext,
        additional: [
          "upstream_port": "\(backend.port)",
          "upstream_path": prepared.endpoint.path,
          "stage": "budget",
          "status_code": "413",
          "error_type": "context_length_exceeded",
        ])
    )
    return backendErrorResult(
      statusCode: 413,
      message: budgetError,
      type: "context_length_exceeded"
    )
  }
  logChatRequestRouted(logContext, upstreamPort: backend.port, upstreamPath: prepared.endpoint.path)
  BackendTrace.notice(
    phase: TracePhase.Broker.requestRouted.rawValue,
    context: routedContext,
    snapshot: .current(),
    extras: chatTraceExtras(
      for: logContext,
      additional: [
        "upstream_port": "\(backend.port)",
        "upstream_path": prepared.endpoint.path,
      ])
  )
  var request = URLRequest(url: upstreamURL, timeoutInterval: 600)
  request.httpMethod = "POST"
  request.httpBody = prepared.bodyData
  request.setValue("application/json", forHTTPHeaderField: "Content-Type")
  request.setValue(logContext.requestID.uuidString, forHTTPHeaderField: "X-LMD-Request-ID")
  if let clientRequestID = logContext.clientRequestID {
    request.setValue(clientRequestID, forHTTPHeaderField: "X-LM-Review-Request-ID")
  }
  if prepared.wantsStream {
    request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
  }

  if prepared.wantsStream {
    do {
      let (bytes, resp) = try await URLSession.shared.bytes(for: request)
      let status = (resp as? HTTPURLResponse)?.statusCode ?? 502
      let contentType =
        (resp as? HTTPURLResponse)?
        .value(forHTTPHeaderField: "Content-Type") ?? "text/event-stream"
      BackendTrace.notice(
        phase: TracePhase.Broker.requestResponseSent.rawValue,
        context: routedContext,
        snapshot: .current(),
        extras: chatTraceExtras(
          for: logContext,
          additional: [
            "upstream_port": "\(backend.port)",
            "upstream_path": prepared.endpoint.path,
            "status_code": "\(status)",
            "content_type": contentType,
          ])
      )
      return .streaming(
        statusCode: status,
        contentType: contentType,
        events: rawBackendStream(
          bytes: bytes,
          lifetimeToken: requestDoneToken,
          onCompleted: {
            logChatRequestCompleted(
              logContext,
              upstreamPort: backend.port,
              upstreamPath: prepared.endpoint.path,
              statusCode: status,
              responseBodyBytes: nil
            )
            BackendTrace.notice(
              phase: TracePhase.Broker.requestCompleted.rawValue,
              context: routedContext,
              snapshot: .current(),
              extras: chatTraceExtras(
                for: logContext,
                additional: [
                  "upstream_port": "\(backend.port)",
                  "upstream_path": prepared.endpoint.path,
                  "status_code": "\(status)",
                ])
            )
          },
          onFailed: { error in
            let fields = safeErrorFields(error)
            logChatRequestFailed(
              logContext,
              upstreamPort: backend.port,
              upstreamPath: prepared.endpoint.path,
              statusCode: status,
              stage: "stream",
              errorType: fields.type,
              errorMessage: fields.message
            )
            BackendTrace.notice(
              phase: TracePhase.Broker.requestFailed.rawValue,
              context: routedContext,
              snapshot: .current(),
              extras: chatTraceExtras(
                for: logContext,
                additional: [
                  "upstream_port": "\(backend.port)",
                  "upstream_path": prepared.endpoint.path,
                  "status_code": "\(status)",
                  "stage": "stream",
                  "error_type": fields.type,
                ])
            )
          }
        ),
        appendDoneFrame: false,
        lifetimeToken: requestDoneToken
      )
    } catch {
      await requestDoneToken.finish()
      let fields = safeErrorFields(error)
      logChatRequestFailed(
        logContext,
        upstreamPort: backend.port,
        upstreamPath: prepared.endpoint.path,
        statusCode: nil,
        stage: "upstream",
        errorType: fields.type,
        errorMessage: fields.message
      )
      BackendTrace.notice(
        phase: TracePhase.Broker.requestFailed.rawValue,
        context: routedContext,
        snapshot: .current(),
        extras: chatTraceExtras(
          for: logContext,
          additional: [
            "upstream_port": "\(backend.port)",
            "upstream_path": prepared.endpoint.path,
            "stage": "upstream",
            "error_type": fields.type,
          ])
      )
      throw error
    }
  }

  // Non-streaming path (buffered).
  do {
    let (data, resp) = try await URLSession.shared.data(for: request)
    let status = (resp as? HTTPURLResponse)?.statusCode ?? 502
    await requestDoneToken.finish()
    logChatRequestCompleted(
      logContext,
      upstreamPort: backend.port,
      upstreamPath: prepared.endpoint.path,
      statusCode: status,
      responseBodyBytes: data.count
    )
    BackendTrace.notice(
      phase: TracePhase.Broker.requestCompleted.rawValue,
      context: routedContext,
      snapshot: .current(),
      extras: chatTraceExtras(
        for: logContext,
        additional: [
          "upstream_port": "\(backend.port)",
          "upstream_path": prepared.endpoint.path,
          "status_code": "\(status)",
          "response_bytes": "\(data.count)",
        ])
    )
    BackendTrace.notice(
      phase: TracePhase.Broker.requestResponseSent.rawValue,
      context: routedContext,
      snapshot: .current(),
      extras: chatTraceExtras(
        for: logContext,
        additional: [
          "upstream_port": "\(backend.port)",
          "upstream_path": prepared.endpoint.path,
          "status_code": "\(status)",
          "response_bytes": "\(data.count)",
        ])
    )
    return .buffered(
      statusCode: status,
      contentType: "application/json",
      body: data
    )
  } catch {
    await requestDoneToken.finish()
    let fields = safeErrorFields(error)
    logChatRequestFailed(
      logContext,
      upstreamPort: backend.port,
      upstreamPath: prepared.endpoint.path,
      statusCode: nil,
      stage: "upstream",
      errorType: fields.type,
      errorMessage: fields.message
    )
    BackendTrace.notice(
      phase: TracePhase.Broker.requestFailed.rawValue,
      context: routedContext,
      snapshot: .current(),
      extras: chatTraceExtras(
        for: logContext,
        additional: [
          "upstream_port": "\(backend.port)",
          "upstream_path": prepared.endpoint.path,
          "stage": "upstream",
          "error_type": fields.type,
        ])
    )
    throw error
  }
}

private func rawBackendStream(
  bytes: URLSession.AsyncBytes,
  lifetimeToken: BackendLifetimeToken,
  onCompleted: @escaping @Sendable () async -> Void = {},
  onFailed: @escaping @Sendable (Error) async -> Void = { _ in }
) -> AsyncThrowingStream<BackendStreamEvent, Error> {
  AsyncThrowingStream<BackendStreamEvent, Error> { continuation in
    let task = Task {
      var iterator = bytes.makeAsyncIterator()
      let chunkSize = 4096
      do {
        while true {
          try Task.checkCancellation()
          var rawBytes: [UInt8] = []
          rawBytes.reserveCapacity(chunkSize)
          while rawBytes.count < chunkSize {
            try Task.checkCancellation()
            guard let byte = try await iterator.next() else {
              break
            }
            rawBytes.append(byte)
          }
          if rawBytes.isEmpty {
            await lifetimeToken.finish()
            await onCompleted()
            continuation.finish()
            return
          }
          continuation.yield(.rawBytes(Data(rawBytes)))
        }
      } catch {
        await lifetimeToken.finish()
        await onFailed(error)
        continuation.finish(throwing: error)
      }
    }
    continuation.onTermination = { @Sendable _ in
      task.cancel()
      Task {
        await lifetimeToken.finish()
      }
    }
  }
}

// MARK: - Helpers

func errorResponse(
  status: HTTPResponse.Status,
  message: String,
  type: String,
  code: String? = nil
) -> Response {
  let env = ErrorEnvelope(
    error: .init(message: message, type: type, code: code)
  )
  let data = (try? JSONEncoder().encode(env)) ?? Data()
  return Response(
    status: status,
    headers: [.contentType: "application/json"],
    body: .init(byteBuffer: ByteBuffer(data: data))
  )
}
