//
//  TUILaunchTests.swift
//  IntegrationTests
//
//  Created by Alex Goodkind <alex@goodkind.io> on 2026-04-18.
//  Copyright © 2026
//
//  Binary-level integration tests for the TUI targets. Spawns each
//  release binary via `Process()`, verifies it paints its top-bar
//  marker within 2s, sends SIGINT, and asserts clean exit within 2s.
//
//  Does NOT assert layout (that's the SwiftLMTUITests snapshot suite).
//  Catches:
//    - binary fails to build/link/load
//    - alt-screen init path crashes
//    - signal-handler wiring is broken (Ctrl-C ignored)
//    - main loop dies before first paint
//
//  Requires release binaries at `$LMD_BINARY_DIR` or
//  `.build/release/`. `make build` produces these; `make test` depends
//  on `make build` so the binaries are always present. When running
//  `swift test` directly without a prior release build, the tests
//  `XCTSkip` with a helpful message rather than fail.
//

import Foundation
import XCTest

final class TUILaunchTests: XCTestCase {
  func testLmdTuiLaunchesAndExitsOnSIGINT() throws {
    try launchAndExitTest(
      binaryName: "lmd-tui",
      expectedMarker: "▌ lmd"
    )
  }

  // MARK: - Shared harness

  /// Spawn the binary, wait up to 2s for `expectedMarker` to appear in
  /// its stdout, then send SIGINT and verify clean exit within 2s.
  private func launchAndExitTest(
    binaryName: String,
    expectedMarker: String,
    file: StaticString = #filePath,
    line: UInt = #line
  ) throws {
    let binary = try resolveBinary(binaryName)
    let proc = Process()
    proc.executableURL = binary

    let stdout = Pipe()
    let stderr = Pipe()
    proc.standardOutput = stdout
    proc.standardError = stderr
    // The TUI will query `stty size`; stdout is a pipe (not a TTY), which
    // causes stty to fall through to the hardcoded fallback (40x120).
    // That's fine for this smoke. We only care that it paints *something*.
    proc.environment = [
      "TERM": "xterm-256color",
      "PATH": ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin",
    ]

    try proc.run()

    // Drain stdout on a background queue into a thread-safe buffer.
    // `Buffer` is a class so the closure captures by reference, which
    // plays correctly with strict concurrency (the NSLock guards
    // access).
    let stdoutBuffer = Buffer()
    let stderrBuffer = Buffer()
    let readHandle = stdout.fileHandleForReading
    let errHandle = stderr.fileHandleForReading
    let drainQueue = DispatchQueue(label: "tui-launch-stdout")
    let stderrQueue = DispatchQueue(label: "tui-launch-stderr")
    drainQueue.async { [weak proc] in
      while proc?.isRunning == true {
        let chunk = readHandle.availableData
        if chunk.isEmpty { continue }
        stdoutBuffer.append(chunk)
      }
    }
    stderrQueue.async { [weak proc] in
      while proc?.isRunning == true {
        let chunk = errHandle.availableData
        if chunk.isEmpty { continue }
        stderrBuffer.append(chunk)
      }
    }

    // Poll for the marker up to 2s.
    let markerDeadline = Date().addingTimeInterval(2.0)
    var saw = false
    var brokerUnavailable = false
    while Date() < markerDeadline {
      let stdoutSnapshot = stdoutBuffer.snapshot()
      let stderrSnapshot = stderrBuffer.snapshot()
      if let text = String(data: stdoutSnapshot, encoding: .utf8),
         text.contains(expectedMarker) {
        saw = true
        break
      }
      if let stderrText = String(data: stderrSnapshot, encoding: .utf8),
         stderrText.contains("lmd-tui: broker unavailable") {
        brokerUnavailable = true
      }
      Thread.sleep(forTimeInterval: 0.05)
    }

    if !saw {
      proc.terminate()
      _ = try? proc.waitUntilExit2(timeout: 1.0)
      if brokerUnavailable {
        let snapshot = String(data: stderrBuffer.snapshot(), encoding: .utf8) ?? "<non-utf8>"
        throw XCTSkip(
          "lmd-tui exited with launch-path message: \(snapshot)"
        )
      }
      // Kill it so we don't leak; dump what we did see for diagnosis.
      let snapshot = stdoutBuffer.snapshot()
      XCTFail(
        """
        \(binaryName) did not paint marker '\(expectedMarker)' within 2s.
        Stdout captured (\(snapshot.count) bytes): \
        \(String(data: snapshot.prefix(500), encoding: .utf8) ?? "<non-utf8>")
        """,
        file: file, line: line
      )
      return
    }

    // Send SIGINT and expect exit within 2s.
    kill(proc.processIdentifier, SIGINT)
    let exited = (try? proc.waitUntilExit2(timeout: 2.0)) ?? false
    if !exited {
      proc.terminate()
      _ = try? proc.waitUntilExit2(timeout: 1.0)
      XCTFail(
        "\(binaryName) did not exit within 2s of SIGINT",
        file: file, line: line
      )
      return
    }
    let code = proc.terminationStatus
    let reason = proc.terminationReason
    // Accept: normal exit with 0, or terminated-by-signal (SIGINT).
    XCTAssertTrue(
      (reason == .exit && code == 0)
        || (reason == .uncaughtSignal && code == SIGINT),
      "\(binaryName) exit code=\(code) reason=\(reason) (expected 0/SIGINT)",
      file: file, line: line
    )
  }

  // MARK: - Binary resolution

  /// Locate the release binary. Uses `$LMD_BINARY_DIR` when set,
  /// otherwise walks up from the test file to find Package.swift and
  /// joins `.build/release/<name>`. Skips the test (not fails) when
  /// the binary is missing. This lets `swift test` run without a
  /// prior `swift build -c release`.
  private func resolveBinary(_ name: String) throws -> URL {
    let env = ProcessInfo.processInfo.environment
    let baseDir: URL
    if let override = env["LMD_BINARY_DIR"], !override.isEmpty {
      baseDir = URL(fileURLWithPath: override)
    } else {
      baseDir = try repoRoot()
        .appendingPathComponent(".build", isDirectory: true)
        .appendingPathComponent("release", isDirectory: true)
    }
    let bin = baseDir.appendingPathComponent(name)
    if !FileManager.default.isExecutableFile(atPath: bin.path) {
      throw XCTSkip(
        """
        release binary not found at \(bin.path). \
        Run `swift build -c release` or `make build` first, or set \
        LMD_BINARY_DIR to a directory containing \(name).
        """
      )
    }
    return bin
  }

  private func repoRoot() throws -> URL {
    var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    while dir.path != "/" {
      if FileManager.default.fileExists(
        atPath: dir.appendingPathComponent("Package.swift").path
      ) {
        return dir
      }
      dir = dir.deletingLastPathComponent()
    }
    throw XCTSkip("could not locate Package.swift above \(#filePath)")
  }
}

// MARK: - Thread-safe byte buffer

/// Small lock-guarded byte accumulator. `Sendable` so the draining
/// closure can capture it under strict concurrency.
private final class Buffer: @unchecked Sendable {
  private let lock = NSLock()
  private var data = Data()

  func append(_ chunk: Data) {
    lock.lock()
    defer { lock.unlock() }
    data.append(chunk)
  }

  func snapshot() -> Data {
    lock.lock()
    defer { lock.unlock() }
    return data
  }
}

// MARK: - Process timed-wait shim

extension Process {
  /// Block up to `timeout` seconds for the process to exit. Returns
  /// `true` if it exited, `false` on timeout.
  func waitUntilExit2(timeout: TimeInterval) throws -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while isRunning {
      if Date() >= deadline { return false }
      Thread.sleep(forTimeInterval: 0.05)
    }
    return true
  }
}
