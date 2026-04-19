//
//  SwiftLMServer.swift
//  SwiftLMBackend
//
//  Created by Alex Goodkind <alex@goodkind.io> on 2026-04-18.
//  Copyright © 2026
//

import AppLogger
import Foundation

private let log = AppLogger.logger(category: "SwiftLMServer")

/// Signposter for long operations (model spawn, process teardown).
/// Emits intervals under category "Performance" so Instruments and
/// xctrace can profile model-load latency without console grepping.
private let signposter = AppLogger.signposter()

// MARK: - Configuration

/// Immutable configuration for a SwiftLM subprocess.
public struct SwiftLMServerConfig: Sendable {
  /// Absolute path to the SwiftLM binary.
  public let binaryPath: String
  /// 127.0.0.1 by default. Only change when binding to another interface.
  public let host: String
  /// TCP port the server listens on.
  public let port: Int
  /// Optional path where stdout/stderr from SwiftLM gets appended.
  public let logFilePath: String?
  /// Time to wait for `/v1/models` to answer 200..499.
  public let readyTimeout: TimeInterval

  public init(
    binaryPath: String,
    host: String = "127.0.0.1",
    port: Int = 5413,
    logFilePath: String? = nil,
    readyTimeout: TimeInterval = 300
  ) {
    self.binaryPath = binaryPath
    self.host = host
    self.port = port
    self.logFilePath = logFilePath
    self.readyTimeout = readyTimeout
  }
}

// MARK: - Errors

/// Failure modes for ``SwiftLMServer``.
public enum SwiftLMServerError: Error, Equatable {
  /// The server process exited before its HTTP surface became ready.
  case exitedBeforeReady(model: String)
  /// The server did not answer `/v1/models` within the timeout.
  case readyTimeout(model: String, seconds: TimeInterval)
  /// The binary path did not exist or was not executable.
  case binaryNotFound(String)
}

// MARK: - SwiftLMServer

/// Supervises a single SwiftLM subprocess.
///
/// The class owns the process, forwards its stdout and stderr to a log
/// file, polls the `/v1/models` endpoint until it responds, and provides
/// a graceful `stop()` that falls back to `SIGKILL` after a timeout.
///
/// A server instance is single-use. Start it once, use it, stop it, then
/// create a fresh instance for the next model.
public final class SwiftLMServer {
  /// The HuggingFace ID or local path passed to SwiftLM via `--model`.
  public let model: String
  /// Whether to pass SwiftLM's `--thinking` flag.
  public let thinking: Bool
  /// Optional sliding-window context size. `nil` uses the model default.
  public let contextSize: Int?

  public let config: SwiftLMServerConfig

  /// The underlying process, once `start()` has been called.
  public private(set) var process: Process?
  /// Pipe owning the server's stdout. Never nil after a successful `start()`.
  public private(set) var stdoutPipe: Pipe?
  /// Pipe owning the server's stderr.
  public private(set) var stderrPipe: Pipe?

  /// Optional plain-text sink for lifecycle messages. Structured events
  /// for this class flow through the shared `os.Logger` under category
  /// `SwiftLMServer`.
  private let logSink: @Sendable (String) -> Void

  public init(
    model: String,
    thinking: Bool = false,
    contextSize: Int? = nil,
    config: SwiftLMServerConfig,
    log: @escaping @Sendable (String) -> Void = { _ in }
  ) {
    self.model = model
    self.thinking = thinking
    self.contextSize = contextSize
    self.config = config
    self.logSink = log
  }

  // MARK: - Lifecycle

  /// Spawn the SwiftLM process.
  ///
  /// - Throws: ``SwiftLMServerError/binaryNotFound(_:)`` if the binary
  ///   path does not exist, or any error thrown by `Process.run()`.
  public func start() throws {
    let span = signposter.beginInterval("server.start", id: signposter.makeSignpostID())
    defer { signposter.endInterval("server.start", span) }
    guard FileManager.default.isExecutableFile(atPath: config.binaryPath) else {
      throw SwiftLMServerError.binaryNotFound(config.binaryPath)
    }
    let p = Process()
    p.launchPath = config.binaryPath
    // MLX looks for default.metallib relative to cwd, so cd into the binary's dir.
    p.currentDirectoryURL = URL(fileURLWithPath: (config.binaryPath as NSString).deletingLastPathComponent)

    var args = ["--model", model, "--port", "\(config.port)", "--host", config.host]
    if thinking {
      args.append("--thinking")
    }
    if let ctx = contextSize {
      args.append("--ctx-size")
      args.append("\(ctx)")
    }
    p.arguments = args

    let so = Pipe()
    let se = Pipe()
    p.standardOutput = so
    p.standardError = se
    self.stdoutPipe = so
    self.stderrPipe = se

    // Mirror stdout/stderr to the configured log file, in append mode.
    if let logPath = config.logFilePath {
      if !FileManager.default.fileExists(atPath: logPath) {
        FileManager.default.createFile(atPath: logPath, contents: nil)
      }
      let fd = open(logPath, O_WRONLY | O_APPEND | O_CREAT, 0o644)
      if fd >= 0 {
        let logFH = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        so.fileHandleForReading.readabilityHandler = { h in
          let d = h.availableData
          if !d.isEmpty { logFH.write(d) }
        }
        se.fileHandleForReading.readabilityHandler = { h in
          let d = h.availableData
          if !d.isEmpty { logFH.write(d) }
        }
      }
    }

    try p.run()
    self.process = p
    log.notice("server.spawned pid=\(p.processIdentifier, privacy: .public) model=\(self.model, privacy: .public) port=\(self.config.port, privacy: .public)")
    logSink("swiftlm-server pid=\(p.processIdentifier) model=\(model) port=\(config.port)")
  }

  /// Poll `/v1/models` until the server responds or the timeout elapses.
  ///
  /// - Returns: `true` if the server became ready, `false` if the timeout
  ///   expired or the process exited first.
  public func waitReady() -> Bool {
    let deadline = Date().addingTimeInterval(config.readyTimeout)
    guard let url = URL(string: "http://\(config.host):\(config.port)/v1/models") else {
      return false
    }
    while Date() < deadline {
      if process?.isRunning != true {
        log.error("server.exited_before_ready model=\(self.model, privacy: .public)")
        logSink("swiftlm-server exited before ready: model=\(model)")
        return false
      }
      let sem = DispatchSemaphore(value: 0)
      var ok = false
      var req = URLRequest(url: url, timeoutInterval: 2)
      req.httpMethod = "GET"
      URLSession.shared.dataTask(with: req) { _, resp, _ in
        if let http = resp as? HTTPURLResponse, (200..<500).contains(http.statusCode) {
          ok = true
        }
        sem.signal()
      }.resume()
      _ = sem.wait(timeout: .now() + 3)
      if ok { return true }
      Thread.sleep(forTimeInterval: 1)
    }
    return false
  }

  /// Terminate the process. Sends SIGTERM, then SIGKILL after 30 seconds.
  public func stop() {
    guard let p = process else { return }
    if p.isRunning {
      p.terminate()
      let deadline = Date().addingTimeInterval(30)
      while p.isRunning && Date() < deadline {
        Thread.sleep(forTimeInterval: 0.2)
      }
      if p.isRunning {
        kill(p.processIdentifier, SIGKILL)
      }
    }
    stdoutPipe?.fileHandleForReading.readabilityHandler = nil
    stderrPipe?.fileHandleForReading.readabilityHandler = nil
    process = nil
    log.notice("server.stopped model=\(self.model, privacy: .public)")
    logSink("swiftlm-server stopped model=\(model)")
  }

  /// True while the underlying process is alive.
  public var isRunning: Bool {
    process?.isRunning ?? false
  }
}
