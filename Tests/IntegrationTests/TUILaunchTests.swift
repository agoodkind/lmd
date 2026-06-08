//
//  TUILaunchTests.swift
//  IntegrationTests
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-04-18.
//  Copyright © 2026, all rights reserved.
//
//  Binary-level integration tests for the TUI targets. Spawns the staged
//  binary via `Process()` attached to a pseudo-terminal, waits for it to paint
//  its top-bar marker, sends SIGINT, and asserts a clean exit.
//
//  The pseudo-terminal matters: the TUI sizes itself by shelling out to
//  `stty size` (see `SwiftLMTUI.Screen.currentSize`), which needs a real
//  terminal with a window size. A plain pipe has neither, so the first paint
//  never lands and the binary appears to hang after alt-screen init. Running
//  the child against a PTY slave with a fixed window makes the launch
//  deterministic everywhere, including a headless CI host with no controlling
//  terminal.
//
//  Does NOT assert layout (that's the SwiftLMTUITests snapshot suite).
//  Catches:
//    - binary fails to build/link/load
//    - alt-screen init path crashes
//    - signal-handler wiring is broken (Ctrl-C ignored)
//    - main loop dies before first paint
//
//  The binary is the most recently built `<name>` across the staged locations
//  for either configuration (`Products/Build/{Debug,Release}` or
//  `.build/{debug,release}`), or `$LMD_BINARY_DIR` when set. This follows
//  whatever the current run built rather than a fixed configuration, so a Debug
//  test run never exercises a stale Release artifact. When no binary is present
//  the tests `XCTSkip` rather than fail.
//

import Darwin
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

  /// Spawn the binary against a pseudo-terminal, wait for `expectedMarker` to
  /// appear in its output, then send SIGINT and verify a clean exit. The waits
  /// tolerate a cold start and return as soon as their condition is met.
  private func launchAndExitTest(
    binaryName: String,
    expectedMarker: String,
    file: StaticString = #filePath,
    line: UInt = #line
  ) throws {
    let binary = try resolveBinary(binaryName)

    // Allocate a pseudo-terminal. The child's stdio is the slave with a fixed
    // window; the test reads the rendered output from the master.
    let master = posix_openpt(O_RDWR | O_NOCTTY)
    guard master >= 0, grantpt(master) == 0, unlockpt(master) == 0,
      let slaveNamePtr = ptsname(master)
    else {
      throw XCTSkip("could not allocate a pseudo-terminal")
    }
    let slaveName = String(cString: slaveNamePtr)
    let slave = open(slaveName, O_RDWR | O_NOCTTY)
    guard slave >= 0 else {
      close(master)
      throw XCTSkip("could not open the pseudo-terminal slave")
    }
    var windowSize = winsize(ws_row: 40, ws_col: 120, ws_xpixel: 0, ws_ypixel: 0)
    _ = withUnsafeMutablePointer(to: &windowSize) { pointer in
      ioctl(slave, UInt(TIOCSWINSZ), pointer)
    }

    let proc = Process()
    proc.executableURL = binary
    let slaveHandle = FileHandle(fileDescriptor: slave, closeOnDealloc: false)
    proc.standardInput = slaveHandle
    proc.standardOutput = slaveHandle
    proc.standardError = slaveHandle
    proc.environment = [
      "TERM": "xterm-256color",
      "PATH": ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin",
    ]

    do {
      try proc.run()
    } catch {
      close(slave)
      close(master)
      throw XCTSkip("could not launch \(binaryName): \(error)")
    }
    // The child holds its own copy of the slave; close ours so the master sees
    // EOF once the child exits.
    close(slave)

    // Drain the master into a buffer until EOF. Uses raw read() so a closed PTY
    // ends the loop cleanly instead of throwing.
    let outputBuffer = Buffer()
    let drainQueue = DispatchQueue(label: "tui-pty-drain")
    drainQueue.async {
      var chunk = [UInt8](repeating: 0, count: 4_096)
      while true {
        let count = chunk.withUnsafeMutableBytes { read(master, $0.baseAddress, $0.count) }
        if count > 0 {
          outputBuffer.append(Data(chunk[0..<count]))
        } else if count < 0, errno == EINTR || errno == EAGAIN {
          continue
        } else {
          break
        }
      }
    }

    // Poll for the marker. With a real terminal the first paint is prompt; the
    // budget only covers a cold start, and the loop exits the instant the
    // marker appears.
    let markerTimeoutSeconds = 5.0
    let markerDeadline = Date().addingTimeInterval(markerTimeoutSeconds)
    var saw = false
    var brokerUnavailable = false
    while Date() < markerDeadline {
      let text = String(data: outputBuffer.snapshot(), encoding: .utf8) ?? ""
      if text.contains(expectedMarker) {
        saw = true
        break
      }
      if text.contains("lmd-tui: broker unavailable") {
        brokerUnavailable = true
      }
      Thread.sleep(forTimeInterval: 0.05)
    }

    if !saw {
      proc.terminate()
      _ = try? proc.waitUntilExit2(timeout: 2.0)
      close(master)
      if brokerUnavailable {
        throw XCTSkip("lmd-tui reported the broker unavailable on its launch path")
      }
      let snapshot = outputBuffer.snapshot()
      XCTFail(
        """
        \(binaryName) did not paint marker '\(expectedMarker)' within \
        \(Int(markerTimeoutSeconds))s.
        Output captured (\(snapshot.count) bytes): \
        \(String(data: snapshot.prefix(500), encoding: .utf8) ?? "<non-utf8>")
        """,
        file: file, line: line
      )
      return
    }

    // Send SIGINT and expect a clean exit.
    kill(proc.processIdentifier, SIGINT)
    let exited = (try? proc.waitUntilExit2(timeout: 5.0)) ?? false
    if !exited {
      proc.terminate()
      _ = try? proc.waitUntilExit2(timeout: 1.0)
      close(master)
      XCTFail(
        "\(binaryName) did not exit within 5s of SIGINT",
        file: file, line: line
      )
      return
    }
    close(master)

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

  /// Locate the binary to smoke-test. Uses `$LMD_BINARY_DIR` when set,
  /// otherwise picks the most recently built `<name>` across the known staged
  /// locations for either configuration. This deliberately does not prefer one
  /// configuration: `make test` builds Debug, so hardcoding Release would test
  /// a different (and possibly stale) artifact than the one under test. Picking
  /// the newest build follows whatever the current run produced. Skips the test
  /// (not fails) when no binary is present, so `swift test` runs without a
  /// prior build.
  private func resolveBinary(_ name: String) throws -> URL {
    let env = ProcessInfo.processInfo.environment
    if let override = env["LMD_BINARY_DIR"], !override.isEmpty {
      let candidate = URL(fileURLWithPath: override).appendingPathComponent(name)
      if FileManager.default.isExecutableFile(atPath: candidate.path) {
        return candidate
      }
    }

    let root = try repoRoot()
    let stagedDirs = [
      root.appendingPathComponent("Products/Build/Debug", isDirectory: true),
      root.appendingPathComponent("Products/Build/Release", isDirectory: true),
      root.appendingPathComponent(".build/debug", isDirectory: true),
      root.appendingPathComponent(".build/release", isDirectory: true),
    ]
    let present =
      stagedDirs
      .map { $0.appendingPathComponent(name) }
      .filter { FileManager.default.isExecutableFile(atPath: $0.path) }

    let newest = present.max { lhs, rhs in
      modificationDate(of: lhs) < modificationDate(of: rhs)
    }
    if let newest {
      return newest
    }
    throw XCTSkip(
      """
      binary not found for \(name). Run `make build` first, or set \
      LMD_BINARY_DIR to a directory containing \(name).
      """
    )
  }

  /// Modification time of `url`, or `.distantPast` when it cannot be read, so a
  /// readable binary always sorts ahead of an unreadable one.
  private func modificationDate(of url: URL) -> Date {
    let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
    return values?.contentModificationDate ?? .distantPast
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
  func waitUntilExit2(timeout: TimeInterval) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while isRunning {
      if Date() >= deadline { return false }
      Thread.sleep(forTimeInterval: 0.05)
    }
    return true
  }
}
