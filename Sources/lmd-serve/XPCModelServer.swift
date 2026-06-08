//
//  XPCModelServer.swift
//  lmd-serve
//
//  Concrete ModelServer: spawns lmd-model-host with Process, writes the spawn
//  token to its stdin, registers the token so the host listener binds the
//  dial-in session here, and exposes send/stats/shutdown. Eviction is session
//  cancel plus SIGKILL, which reclaims the child's memory.
//

import AppLogger
import Foundation
import LMDServeSupport
import SwiftLMCore
import SwiftLMHostProtocol
import SwiftLMMetrics
import SwiftLMRuntime
import XPC

private let log = AppLogger.logger(category: "XPCModelServer")

final class XPCModelServer: ModelServer, @unchecked Sendable {
  let modelID: String
  let sizeBytes: Int64

  private let kind: BackendKind
  private let modelPath: String
  private let hostBinaryPath: String
  private let hostService: String
  private let pending: PendingSpawns
  private let swiftLMBinaryPath: String?
  private let swiftLMLogPath: String?
  private let contextLength: Int?
  // Sampling rate forwarded to a video host so it samples frames at the rate the
  // model's preprocessor expects. nil for non-video kinds.
  private let videoSamplingFPS: Double?

  private let lock = NSLock()
  private var process: Process?
  private var session: XPCSession?
  private var lastStats = BackendStats(rssBytes: 0, gpuActiveBytes: 0, gpuCacheBytes: 0)
  private var lastMetricsSnapshot: MetricsSnapshot?
  private var readyContinuation: CheckedContinuation<Void, Error>?
  private var isReady = false
  private var streams: [UUID: AsyncThrowingStream<BackendFrame, Error>.Continuation] = [:]

  init(
    descriptor: ModelDescriptor,
    kind: BackendKind,
    hostBinaryPath: String,
    hostService: String,
    pending: PendingSpawns,
    swiftLMBinaryPath: String? = nil,
    swiftLMLogPath: String? = nil,
    contextLength: Int? = nil,
    videoSamplingFPS: Double? = nil
  ) {
    self.modelID = descriptor.id
    self.sizeBytes = descriptor.sizeBytes
    self.kind = kind
    self.modelPath = descriptor.path
    self.hostBinaryPath = hostBinaryPath
    self.hostService = hostService
    self.pending = pending
    self.swiftLMBinaryPath = swiftLMBinaryPath
    self.swiftLMLogPath = swiftLMLogPath
    self.contextLength = contextLength
    self.videoSamplingFPS = videoSamplingFPS
  }

  var isRunning: Bool {
    withLock {
      process?.isRunning ?? false
    }
  }

  // Runs `body` under the lock from a synchronous scope. Swift 6 forbids
  // calling NSLock.lock()/unlock() directly from an async context, so the
  // async methods funnel their critical sections through this helper.
  private func withLock<Result>(_ body: () -> Result) -> Result {
    lock.lock()
    defer { lock.unlock() }
    return body()
  }

  // Called by the host listener when a dial-in's hello token matches.
  func bind(session: XPCSession) {
    lock.lock()
    self.session = session
    lock.unlock()
  }

  func deliver(_ frame: BackendFrame) {
    switch frame {
    case .ready:
      lock.lock()
      isReady = true
      let cont = readyContinuation
      readyContinuation = nil
      lock.unlock()
      cont?.resume()
    case .stats(let rss, let active, let cache):
      lock.lock()
      lastStats = BackendStats(rssBytes: rss, gpuActiveBytes: active, gpuCacheBytes: cache)
      lock.unlock()
    case .responseStarted(let id, _, _), .chunk(let id, _), .vectors(let id, _, _),
      .usage(let id, _, _):
      lock.lock()
      let cont = streams[id]
      lock.unlock()
      cont?.yield(frame)
    case .done(let id):
      lock.lock()
      let cont = streams.removeValue(forKey: id)
      lock.unlock()
      cont?.yield(frame)
      cont?.finish()
    case .failed(let id, _):
      lock.lock()
      let cont = streams.removeValue(forKey: id)
      lock.unlock()
      cont?.yield(frame)
      cont?.finish()
    case .metricsSnapshot(let data):
      do {
        let snapshot = try MetricsJSON.decodeSnapshot(data)
        lock.lock()
        lastMetricsSnapshot = snapshot
        lock.unlock()
      } catch {
        log.error(
          "host.metrics_snapshot_decode_failed model=\(self.modelID, privacy: .public) err=\(String(describing: error), privacy: .public)"
        )
      }
    case .hello:
      break
    }
  }

  func spawn() async throws {
    let token = UUID().uuidString
    await pending.register(token: token, modelID: modelID)

    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: hostBinaryPath)
    // MLX loads its metallib relative to cwd; the host lives beside it.
    proc.currentDirectoryURL = URL(
      fileURLWithPath: (hostBinaryPath as NSString).deletingLastPathComponent)
    var arguments = [
      "--model", modelPath,
      "--kind", kind.rawValue,
      "--host-service", hostService,
    ]
    if let videoSamplingFPS {
      arguments.append(contentsOf: ["--video-sampling-fps", String(videoSamplingFPS)])
    }
    if let swiftLMBinaryPath {
      arguments.append(contentsOf: ["--swiftlm-binary", swiftLMBinaryPath])
    }
    if let swiftLMLogPath {
      arguments.append(contentsOf: ["--swiftlm-log-path", swiftLMLogPath])
    }
    if let contextLength {
      arguments.append(contentsOf: ["--context-length", String(contextLength)])
    }
    proc.arguments = arguments
    let stdinPipe = Pipe()
    proc.standardInput = stdinPipe
    do {
      try proc.run()
    } catch {
      await pending.drop(token: token)
      throw ModelServerError.spawnFailed(modelID: modelID, message: "\(error)")
    }
    withLock { self.process = proc }
    // Write the token then keep stdin open; closing it later signals exit.
    stdinPipe.fileHandleForWriting.write(Data((token + "\n").utf8))
    log.notice(
      "host.spawned model=\(self.modelID, privacy: .public) pid=\(proc.processIdentifier, privacy: .public)"
    )
  }

  func waitReady() async throws {
    let alreadyReady = withLock { isReady }
    if alreadyReady { return }
    try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
      withLock { readyContinuation = cont }
    }
  }

  func send(_ request: BackendRequest) -> AsyncThrowingStream<BackendFrame, Error> {
    AsyncThrowingStream { continuation in
      lock.lock()
      streams[request.requestID] = continuation
      let session = self.session
      lock.unlock()
      guard let session else {
        continuation.finish(throwing: ModelServerError.sessionLost(modelID: modelID))
        return
      }
      do {
        try session.send(HostInbound.request(request))
      } catch {
        continuation.finish(throwing: error)
      }
    }
  }

  func stats() -> BackendStats {
    withLock { lastStats }
  }

  func metricsSnapshot() -> MetricsSnapshot? {
    withLock { lastMetricsSnapshot }
  }

  // Forward a battery throttle level to the host as an out-of-band control
  // message. Best-effort: a missing or failed session is logged and dropped,
  // since the next spawn inherits the level and a throttle change is not a
  // request whose failure the caller can act on.
  func applyPowerThrottle(_ level: ThrottleLevel) {
    let session = withLock { self.session }
    guard let session else {
      log.notice(
        "host.power_throttle_no_session model=\(self.modelID, privacy: .public) level=\(level.rawValue, privacy: .public)"
      )
      return
    }
    do {
      try session.send(HostInbound.control(.applyPowerThrottle(level)))
    } catch {
      log.error(
        "host.power_throttle_send_failed model=\(self.modelID, privacy: .public) err=\(String(describing: error), privacy: .public)"
      )
    }
  }

  func shutdown() {
    lock.lock()
    let proc = process
    session?.cancel(reason: "evicted")
    session = nil
    process = nil
    lock.unlock()
    guard let proc else {
      log.notice("host.shutdown model=\(self.modelID, privacy: .public)")
      return
    }
    proc.terminate()
    // Grace window: the helper's SIGTERM handler reaps its SwiftLM child and
    // exits. Only SIGKILL if it overstays. Run off the actor so teardown never
    // blocks. Capture the pid (Sendable) and probe with signal 0 so the closure
    // does not capture the non-Sendable Process.
    let pid = proc.processIdentifier
    let modelID = self.modelID
    Task.detached {
      let deadline = Date().addingTimeInterval(5)
      while kill(pid, 0) == 0, Date() < deadline {
        try? await Task.sleep(nanoseconds: 100_000_000)
      }
      if kill(pid, 0) == 0 {
        kill(pid, SIGKILL)
        log.notice("host.shutdown_sigkill model=\(modelID, privacy: .public)")
      }
    }
    log.notice("host.shutdown model=\(self.modelID, privacy: .public)")
  }
}
