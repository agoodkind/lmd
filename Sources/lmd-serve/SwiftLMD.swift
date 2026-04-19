//
//  SwiftLMD.swift
//  lmd-serve
//
//  Created by Alex Goodkind <alex@goodkind.io> on 2026-04-18.
//  Copyright © 2026
//
//  lmd-serve: persistent broker daemon.
//
//  Owns SwiftLM lifecycle, the model catalog, the router/eviction
//  policy, sensor sampling (formerly swiftmon), and fan control.
//  Exposes an OpenAI-compatible HTTP API on port 5400 by default.
//

import AppLogger
import Foundation
import Hummingbird
import SwiftLMBackend
import SwiftLMCore
import SwiftLMEmbed
import SwiftLMMonitor
import SwiftLMRuntime

// File-scope os.Logger. `@main` mode forbids top-level expressions, so
// the `AppLogger.bootstrap` call lives inside `SwiftLMD.main()` below.
// The `log` handle itself is a constant and is safe to create at file
// scope; it will be usable immediately after bootstrap runs at startup.
private let log = AppLogger.logger(category: "Broker")

// MARK: - Defaults

let defaultBrokerHost = "127.0.0.1"
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

/// Classify a router log line into a `BrokerEvent` and publish it to
/// the shared bus. Best-effort string parsing; unknown shapes fall
/// through to `.note`.
func publishRouterEvent(message: String) {
  let kind: BrokerEvent.Kind
  var model: String?
  if message.contains("spawned model=") || message.contains("spawned embedding model=") {
    kind = .modelLoaded
    model = extractModel(from: message)
  } else if message.contains("unloaded model=") || message.contains("unloaded embedding model=") {
    kind = .modelUnloaded
    model = extractModel(from: message)
  } else if message.contains("evict") {
    kind = .modelEvicted
    model = extractModel(from: message)
  } else {
    kind = .note
  }
  Task { await EventBus.shared.publish(kind: kind, model: model, message: message) }
}

/// Pick the model id out of a "key=value" router log line.
private func extractModel(from message: String) -> String? {
  guard let range = message.range(of: "model=") else { return nil }
  let tail = message[range.upperBound...]
  return tail.split(separator: " ", maxSplits: 1).first.map(String.init)
}

// MARK: - Legacy `slog` shim
//
// Routes the broker's existing `slog("...")` call sites through the
// unified `os.Logger` at `.notice` level so operators tail via
// `log stream --subsystem io.goodkind.lmd --info`. Kept as a helper
// because several library callbacks (ModelRouter, SwiftLMServer)
// accept a `(String) -> Void` sink that this satisfies.
//
// Messages are marked `.public` because the broker does not handle
// user prompt text through this channel. It only carries lifecycle
// traces. New first-party code writes events via `log.<level>(...)`
// with per-value privacy annotations per Rule 3.
func slog(_ message: String) {
  log.notice("\(message, privacy: .public)")
}

// MARK: - Memory budget

func defaultMemoryBudget() -> MemoryBudget {
  let envKey = ProcessInfo.processInfo.environment["LMD_BUDGET_GB"]
  let budgetGB = Int64(envKey ?? "") ?? 80
  let gigabyte: Int64 = 1_073_741_824
  return MemoryBudget(ceilingBytes: budgetGB * gigabyte)
}

// MARK: - Live backend adapter

final class LiveBackend: SwiftLMBackendProtocol, @unchecked Sendable {
  let modelID: String
  let port: Int
  let sizeBytes: Int64
  private let server: SwiftLMServer

  init(model: ModelDescriptor, port: Int, binaryPath: String, logPath: String?) {
    self.modelID = model.id
    self.port = port
    self.sizeBytes = model.sizeBytes
    self.server = SwiftLMServer(
      model: model.path,
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

/// Everything the HTTP handlers need. The router is a `ModelRouter` actor.
final class BrokerState: @unchecked Sendable {
  let catalog: ModelCatalog
  let router: ModelRouter
  let modelsByID: [String: ModelDescriptor]
  let downloadCoordinator: HubDownloadCoordinator

  init(catalog: ModelCatalog, router: ModelRouter, models: [ModelDescriptor]) {
    self.catalog = catalog
    self.router = router
    self.downloadCoordinator = HubDownloadCoordinator()
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
    modelsByID[id]
  }
}

// MARK: - OpenAI JSON schemas

struct OpenAIModelsResponse: Codable {
  let object: String
  let data: [ModelEntry]

  struct ModelEntry: Codable {
    let id: String
    let object: String
    let created: Int
    let owned_by: String  // swiftlint:disable:this identifier_name
    let kind: String
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

    // Budget and binary
    let budget = defaultMemoryBudget()
    slog("budget: ceiling=\(budget.ceilingBytes / 1_073_741_824) GB")

    let binary = ProcessInfo.processInfo.environment["LMD_SWIFTLM_BINARY"] ?? defaultSwiftLMBinary
    guard FileManager.default.isExecutableFile(atPath: binary) else {
      slog("ERROR: SwiftLM binary not executable at \(binary)")
      exit(1)
    }

    // Router. The plain-text log callback tees into `slog` and into the
    // shared `EventBus` so subscribers (`/swiftlmd/events`, future
    // EventsTab) see lifecycle transitions.
    let router = ModelRouter(
      budget: budget,
      spawner: { model, port in
        LiveBackend(model: model, port: port, binaryPath: binary, logPath: defaultLogPath)
      },
      embeddingSpawner: { model in
        let backend = MLXEmbeddingBackend(descriptor: model)
        try await backend.launch()
        return backend
      },
      log: { message in
        slog("router: \(message)")
        publishRouterEvent(message: message)
      }
    )

    let state = BrokerState(catalog: catalog, router: router, models: models)

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
    let embedIdleMinutes = Int(ProcessInfo.processInfo.environment["LMD_EMBEDDING_IDLE_MINUTES"] ?? "") ?? 60
    let embedIdleCutoff = TimeInterval(embedIdleMinutes * 60)
    Task {
      while !Task.isCancelled {
        try? await Task.sleep(nanoseconds: 60 * 1_000_000_000)
        let snap = await router.snapshot()
        let now = Date()
        for c in snap.loaded where c.isIdle && !c.isEmbedding
          && now.timeIntervalSince(c.lastUsed) >= chatIdleCutoff {
          slog("idle-unload: \(c.modelID) (chat, last used \(Int(now.timeIntervalSince(c.lastUsed)))s ago)")
          await router.unload(modelID: c.modelID)
        }
        for c in snap.loaded where c.isIdle && c.isEmbedding
          && now.timeIntervalSince(c.lastUsed) >= embedIdleCutoff {
          slog("idle-unload: \(c.modelID) (embedding, last used \(Int(now.timeIntervalSince(c.lastUsed)))s ago)")
          await router.unload(modelID: c.modelID)
        }
      }
    }

    // Sensor sampler: replaces the standalone swiftmon daemon. Runs as
    // a background Task inside the broker and writes a JSONL record
    // every `LMD_SAMPLE_INTERVAL` seconds under `LMD_DATA_DIR`.
    let dataDir = ProcessInfo.processInfo.environment["LMD_DATA_DIR"]
      ?? "\(NSHomeDirectory())/Library/Application Support/io.goodkind.lmd"
    let sampleInterval = Double(ProcessInfo.processInfo.environment["LMD_SAMPLE_INTERVAL"] ?? "") ?? 15
    let sampler = SensorSampler(config: .init(
      baseDir: dataDir,
      intervalSeconds: sampleInterval
    ))
    sampler.start()

    // Fan coordinator: takes over fan control for the life of the
    // broker so temperature limits track the chip's real load instead
    // of Apple's conservative default curve. The LLM-active signal
    // reads the router's in-flight request count on every tick.
    let fan = FanCoordinator(
      config: FanCoordinatorConfig(
        smcfanBinary: ProcessInfo.processInfo.environment["LMD_SMCFAN_BINARY"]
          ?? "/Users/agoodkind/Sites/macos-smc-fan/Products/smcfan"
      ),
      log: { message in slog("fan: \(message)") }
    )
    fan.takeOver()
    atexit {
      // atexit cannot call instance methods directly. The coordinator
      // instance is a class, so stash a static handle and call through.
      FanHandoff.shared?.release()
    }
    FanHandoff.shared = fan

    // Background loop: sample macmon every 2s, feed temps + in-flight
    // count into FanCoordinator.apply. The coordinator itself rate
    // limits smcfan writes so the 2s tick does not cause wear.
    Task {
      let macmon = MacmonClient()
      while !Task.isCancelled {
        let snap = macmon.fetch()
        let routerSnap = await router.snapshot()
        let inFlight = routerSnap.loaded.reduce(0) { $0 + $1.inFlightRequests }
        fan.apply(
          FanInputs(
            cpuTempC: snap.cpuTempC,
            gpuTempC: snap.gpuTempC,
            cpuPercent: snap.cpuPercent,
            gpuPercent: snap.gpuPercent,
            pressureFreePct: 100,
            llmLoaded: inFlight > 0
          )
        )
        // 500ms ticks so a just-arrived request flips llmLoaded=true
        // within half a second instead of missing a 2s window. The
        // coordinator still rate-limits actual smcfan writes via its
        // own internal cooldown, so the faster loop does not cause
        // fan wear.
        try? await Task.sleep(nanoseconds: 500_000_000)
      }
    }

    // HTTP router
    let httpRouter = Router()
    registerRoutes(on: httpRouter, state: state)

    let host = ProcessInfo.processInfo.environment["LMD_HOST"] ?? defaultBrokerHost
    let port = Int(ProcessInfo.processInfo.environment["LMD_PORT"] ?? "") ?? defaultBrokerPort
    slog("HTTP server starting on \(host):\(port)")

    let app = Application(
      router: httpRouter,
      configuration: .init(
        address: .hostname(host, port: port),
        serverName: "swiftlmd/\(SwiftLMCore.version)"
      )
    )
    try await app.runService()
  }
}

// MARK: - Fan handoff
//
// `atexit` handlers are C callbacks so they cannot capture Swift
// instance methods directly. Stashing the coordinator in a static
// holder lets the process tear-down path release fans to Apple's
// native controller no matter how the broker exits. The shared
// reference is set once by `SwiftLMD.main` after the coordinator
// takes over.

enum FanHandoff {
  nonisolated(unsafe) static var shared: FanCoordinator?
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
          kind: m.kind.rawValue
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
    struct Loaded: Codable {
      let models: [Entry]
      let allocated_gb: Double  // swiftlint:disable:this identifier_name
      struct Entry: Codable {
        let model_id: String           // swiftlint:disable:this identifier_name
        let size_gb: Double            // swiftlint:disable:this identifier_name
        let last_used: String          // swiftlint:disable:this identifier_name
        let in_flight_requests: Int    // swiftlint:disable:this identifier_name
        let kind: String
      }
    }
    let entries = snap.loaded.map { c in
      let kind = state.modelsByID[c.modelID]?.kind.rawValue ?? "chat"
      return Loaded.Entry(
        model_id: c.modelID,
        size_gb: Double(c.sizeBytes) / 1_073_741_824,
        last_used: isoFormatter.string(from: c.lastUsed),
        in_flight_requests: c.inFlightRequests,
        kind: kind
      )
    }
    let body = Loaded(
      models: entries,
      allocated_gb: Double(snap.allocatedBytes) / 1_073_741_824
    )
    let data = try JSONEncoder().encode(body)
    return Response(
      status: .ok,
      headers: [.contentType: "application/json"],
      body: .init(byteBuffer: ByteBuffer(data: data))
    )
  }

  router.post("/v1/embeddings") { req, _ async throws -> Response in
    try await handleEmbeddings(req: req, state: state)
  }

  // /v1/chat/completions and /v1/completions: parse, JIT-route, proxy.
  router.post("/v1/chat/completions") { req, _ async throws -> Response in
    try await proxyChat(path: "/v1/chat/completions", req: req, state: state)
  }
  router.post("/v1/completions") { req, _ async throws -> Response in
    try await proxyChat(path: "/v1/completions", req: req, state: state)
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
    guard let json = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any],
          let modelID = json["model"] as? String
    else {
      return errorResponse(status: .badRequest, message: "missing `model`", type: "invalid_request_error")
    }
    guard let descriptor = state.resolve(id: modelID) else {
      return errorResponse(status: .notFound, message: "unknown model \(modelID)", type: "model_not_found")
    }
    do {
      if descriptor.kind == .embedding {
        _ = try await state.router.routeEmbeddingAndBegin(descriptor)
        await state.router.embeddingRequestDone(modelID: descriptor.id)
      } else {
        _ = try await state.router.routeAndBegin(descriptor)
        await state.router.requestDone(modelID: descriptor.id)
      }
    } catch {
      return errorResponse(
        status: .serviceUnavailable,
        message: "preload failed: \(error)",
        type: "preload_failed"
      )
    }
    let body = ByteBuffer(string: #"{"status":"ready","model":"\#(openAIModelId(descriptor))"}"#)
    return Response(
      status: .accepted,
      headers: [.contentType: "application/json"],
      body: .init(byteBuffer: body)
    )
  }

  // POST /swiftlmd/unload  body {"model": "<id>"}
  //   Force-unloads a model even if it was loaded moments ago.
  router.post("/swiftlmd/unload") { req, _ async throws -> Response in
    let bodyBuffer = try await req.body.collect(upTo: 1024 * 1024)
    let bodyData = Data(buffer: bodyBuffer)
    guard let json = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any],
          let modelID = json["model"] as? String
    else {
      return errorResponse(status: .badRequest, message: "missing `model`", type: "invalid_request_error")
    }
    await state.router.unload(modelID: modelID)
    let body = ByteBuffer(string: #"{"status":"unloaded","model":"\#(modelID)"}"#)
    return Response(
      status: .ok,
      headers: [.contentType: "application/json"],
      body: .init(byteBuffer: body)
    )
  }
}

// MARK: - Embeddings

func handleEmbeddings(req: Request, state: BrokerState) async throws -> Response {
  let bodyBuffer = try await req.body.collect(upTo: 32 * 1024 * 1024)
  let bodyData = Data(buffer: bodyBuffer)
  guard let json = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any],
        let modelField = json["model"] as? String
  else {
    return errorResponse(status: .badRequest, message: "missing `model` field", type: "invalid_request_error")
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

  let backend: EmbeddingBackendProtocol
  do {
    backend = try await state.router.routeEmbeddingAndBegin(descriptor)
  } catch let err as ModelRouter.RouteError {
    switch err {
    case .cannotFitInBudget:
      return errorResponse(
        status: .serviceUnavailable,
        message: "cannot fit embedding model in memory budget",
        type: "capacity_exceeded"
      )
    case .backendLaunchFailed:
      return errorResponse(
        status: .serviceUnavailable,
        message: "failed to load embedding model",
        type: "launch_failed"
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
  let vectors: [[Float]]
  do {
    vectors = try await backend.embed(inputs: inputs)
  } catch {
    await state.router.embeddingRequestDone(modelID: descriptor.id)
    return errorResponse(
      status: .serviceUnavailable,
      message: "embedding failed: \(error)",
      type: "embedding_failed"
    )
  }
  await state.router.embeddingRequestDone(modelID: descriptor.id)

  struct EmbRow: Codable {
    let object: String
    let embedding: [Float]
    let index: Int
  }
  struct EmbOut: Codable {
    let object: String
    let data: [EmbRow]
    let model: String
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
  return Response(
    status: .ok,
    headers: [.contentType: "application/json"],
    body: .init(byteBuffer: ByteBuffer(data: data))
  )
}

// MARK: - Proxy logic

func proxyChat(path: String, req: Request, state: BrokerState) async throws -> Response {
  // Buffer the request body so we can peek at `model`, `stream`, and
  // `response_format`, then forward (possibly rewritten) to upstream.
  let bodyBuffer = try await req.body.collect(upTo: 100 * 1024 * 1024)
  var bodyData = Data(buffer: bodyBuffer)

  guard var json = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any],
        let modelID = json["model"] as? String
  else {
    return errorResponse(
      status: .badRequest,
      message: "missing `model` field",
      type: "invalid_request_error"
    )
  }
  let wantsStream = (json["stream"] as? Bool) ?? false

  // JSON enforcement middleware. Local SwiftLM does not implement
  // grammar-constrained decoding, so `response_format` is otherwise
  // silently ignored. We inject a system message instructing the model to
  // emit JSON; combined with the already-reliable Qwen coder family this
  // lifts parse rate from roughly 50% to nearly 100% in practice.
  if let rewritten = injectJSONInstructionIfNeeded(&json) {
    bodyData = rewritten
  }

  guard let descriptor = state.resolve(id: modelID) else {
    return errorResponse(
      status: .notFound,
      message: "model not found: \(modelID). try GET /v1/models",
      type: "model_not_found",
      code: "model_not_found"
    )
  }

  if descriptor.kind == .embedding {
    return errorResponse(
      status: .badRequest,
      message: "model is an embedding model; use POST /v1/embeddings",
      type: "invalid_request_error"
    )
  }

  let backend: SwiftLMBackendProtocol
  do {
    backend = try await state.router.routeAndBegin(descriptor)
  } catch let err as ModelRouter.RouteError {
    switch err {
    case .cannotFitInBudget:
      return errorResponse(
        status: .serviceUnavailable,
        message: "cannot fit \(descriptor.displayName) in memory budget",
        type: "capacity_exceeded"
      )
    case .noFreePort:
      return errorResponse(
        status: .serviceUnavailable,
        message: "no free port in pool",
        type: "capacity_exceeded"
      )
    case .backendLaunchFailed:
      return errorResponse(
        status: .serviceUnavailable,
        message: "failed to launch model \(descriptor.displayName)",
        type: "launch_failed"
      )
    case .wrongKindForChat:
      return errorResponse(
        status: .badRequest,
        message: "model is an embedding model; use POST /v1/embeddings",
        type: "invalid_request_error"
      )
    case .wrongKindForEmbedding, .embeddingSpawnerMissing:
      return errorResponse(
        status: .internalServerError,
        message: "router configuration error",
        type: "internal_error"
      )
    }
  }

  let upstreamURL = URL(string: "http://127.0.0.1:\(backend.port)\(path)")!
  var request = URLRequest(url: upstreamURL, timeoutInterval: 600)
  request.httpMethod = "POST"
  request.httpBody = bodyData
  request.setValue("application/json", forHTTPHeaderField: "Content-Type")
  if wantsStream {
    request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
  }

  if wantsStream {
    // Streaming path: proxy the SSE chunks back to the client as they arrive.
    let modelIDCopy = descriptor.id
    let router = state.router
    do {
      let (bytes, resp) = try await URLSession.shared.bytes(for: request)
      let status = (resp as? HTTPURLResponse)?.statusCode ?? 502
      let contentType = (resp as? HTTPURLResponse)?
        .value(forHTTPHeaderField: "Content-Type") ?? "text/event-stream"

      let responseBody = ResponseBody(asyncSequence: AsyncURLBytesSequence(bytes: bytes) {
        Task { await router.requestDone(modelID: modelIDCopy) }
      })

      return Response(
        status: .init(code: numericCast(status)),
        headers: [
          .contentType: contentType,
          .cacheControl: "no-cache",
        ],
        body: responseBody
      )
    } catch {
      await state.router.requestDone(modelID: descriptor.id)
      throw error
    }
  }

  // Non-streaming path (buffered).
  do {
    let (data, resp) = try await URLSession.shared.data(for: request)
    let status = (resp as? HTTPURLResponse)?.statusCode ?? 502
    await state.router.requestDone(modelID: descriptor.id)
    return Response(
      status: .init(code: numericCast(status)),
      headers: [.contentType: "application/json"],
      body: .init(byteBuffer: ByteBuffer(data: data))
    )
  } catch {
    await state.router.requestDone(modelID: descriptor.id)
    throw error
  }
}

// MARK: - AsyncSequence wrapper for upstream SSE bytes

/// Adapts `URLSession.AsyncBytes` into a `ByteBuffer` stream and fires
/// `onFinish` exactly once so the router can drop the in-flight count.
///
/// We batch raw bytes into fixed-size chunks rather than parsing SSE frames,
/// because the SwiftLM upstream already writes complete SSE chunks and the
/// HTTP client just needs to forward bytes transparently. The chunk size
/// is a throughput/latency trade; 4 KiB keeps tokens flowing promptly.
struct AsyncURLBytesSequence: AsyncSequence, Sendable {
  typealias Element = ByteBuffer

  let bytes: URLSession.AsyncBytes
  let onFinish: @Sendable () -> Void
  let chunkSize: Int = 4096

  func makeAsyncIterator() -> Iterator {
    Iterator(upstream: bytes.makeAsyncIterator(), onFinish: onFinish, chunkSize: chunkSize)
  }

  struct Iterator: AsyncIteratorProtocol {
    var upstream: URLSession.AsyncBytes.AsyncIterator
    let onFinish: @Sendable () -> Void
    let chunkSize: Int
    var finished = false

    init(upstream: URLSession.AsyncBytes.AsyncIterator, onFinish: @escaping @Sendable () -> Void, chunkSize: Int) {
      self.upstream = upstream
      self.onFinish = onFinish
      self.chunkSize = chunkSize
    }

    mutating func next() async throws -> ByteBuffer? {
      var bytes = [UInt8]()
      bytes.reserveCapacity(chunkSize)
      while bytes.count < chunkSize {
        guard let byte = try await upstream.next() else { break }
        bytes.append(byte)
      }
      if bytes.isEmpty {
        if !finished {
          finished = true
          onFinish()
        }
        return nil
      }
      return ByteBuffer(bytes: bytes)
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
