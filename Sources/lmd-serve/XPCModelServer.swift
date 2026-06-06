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
  // Sampling rate forwarded to a video host so it samples frames at the rate the
  // model's preprocessor expects. nil for non-video kinds.
  private let videoSamplingFPS: Double?

  private let lock = NSLock()
  private var process: Process?
  private var session: XPCSession?
  private var lastStats = BackendStats(rssBytes: 0, gpuActiveBytes: 0, gpuCacheBytes: 0)
  private var readyContinuation: CheckedContinuation<Void, Error>?
  private var isReady = false
  private var streams: [UUID: AsyncThrowingStream<BackendFrame, Error>.Continuation] = [:]

  init(
    descriptor: ModelDescriptor,
    kind: BackendKind,
    hostBinaryPath: String,
    hostService: String,
    pending: PendingSpawns,
    videoSamplingFPS: Double? = nil
  ) {
    self.modelID = descriptor.id
    self.sizeBytes = descriptor.sizeBytes
    self.kind = kind
    self.modelPath = descriptor.path
    self.hostBinaryPath = hostBinaryPath
    self.hostService = hostService
    self.pending = pending
    self.videoSamplingFPS = videoSamplingFPS
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
    case .chunk(let id, _), .vectors(let id, _, _), .usage(let id, _, _):
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
    case .hello, .metricsSnapshot:
      break  // hello handled at bind time; metrics handled by the metrics task
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
        try session.send(request)
      } catch {
        continuation.finish(throwing: error)
      }
    }
  }

  func stats() async -> BackendStats {
    withLock { lastStats }
  }

  func shutdown() {
    lock.lock()
    let proc = process
    session?.cancel(reason: "evicted")
    session = nil
    process = nil
    lock.unlock()
    proc?.terminate()
    if let proc, proc.isRunning {
      kill(proc.processIdentifier, SIGKILL)
    }
    log.notice("host.shutdown model=\(self.modelID, privacy: .public)")
  }
}
