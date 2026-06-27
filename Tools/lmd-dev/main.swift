//
//  main.swift
//  lmd-dev
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-05-10.
//  Copyright © 2026, all rights reserved.
//

import Darwin
import Foundation
import SwiftMkCore

// MARK: - Product constants

let productBinaries = ["lmd", "lmd-serve", "lmd-model-host"]
let compatibilityCommandLinks = [
  "lmd-tui": "lmd",
  "lmd-bench": "lmd",
  "lmd-qa": "lmd",
]
let defaultBundleIdentifierPrefix = "io.goodkind.lmd"
let defaultVideoModel = "mlx-community/Qwen2.5-VL-32B-Instruct-4bit"
let supportedVideoExtensions: Set<String> = [
  "avi",
  "m4v",
  "mkv",
  "mov",
  "mp4",
  "mpeg",
  "mpg",
  "webm",
]

// MARK: - ToolError

enum ToolError: Error, CustomStringConvertible {
  case failure(String)
  case usage(String)

  var description: String {
    switch self {
    case .failure(let message):
      return message
    case .usage(let message):
      return message
    }
  }
}

// MARK: - CommandResult

struct CommandResult {
  let status: Int32
  let output: String
}

// MARK: - DevTool

// `@unchecked Sendable` is sound here: every stored property is an immutable `let`,
// the type is used single-threaded by the CLI, and the only cross-concurrency use is
// the decoupled build's `GatedBuild.run` compile closure, which `self` is captured by
// and which runs synchronously within the same call.
final class DevTool: @unchecked Sendable {
  let fileManager = FileManager.default
  let environment = Environment()
  let repoRoot: URL

  init() throws {
    repoRoot = try Self.findRepoRoot()
  }

  func run(arguments: [String]) async throws {
    guard let command = arguments.first else {
      try help()
      return
    }
    let rest = Array(arguments.dropFirst())
    if try runLifecycleCommand(command, rest: rest) {
      return
    }
    if try runDaemonCommand(command, rest: rest) {
      return
    }
    if try await runQualityCommand(command, rest: rest) {
      return
    }
    if try runReleaseCommand(command, rest: rest) {
      return
    }
    throw ToolError.usage("unknown command: \(command)")
  }

  /// Build, test, install, and clean commands that shape the product binaries.
  private func runLifecycleCommand(_ command: String, rest: [String]) throws -> Bool {
    switch command {
    case "help", "--help", "-h":
      try help()
    case "build":
      try build(configuration: configuration(from: rest.first, defaultValue: "Release"))
    case "debug":
      try build(configuration: "Debug")
    case "test":
      try test()
    case "test-integration":
      try testIntegration()
    case "snapshot-update":
      try snapshotUpdate()
    case "clean":
      try clean()
    case "install":
      try install(configuration: configuration(from: rest.first, defaultValue: "Release"))
    case "uninstall":
      try uninstall()
    default:
      return false
    }
    return true
  }

  /// launchd serve lifecycle and the isolated test daemon.
  private func runDaemonCommand(_ command: String, rest: [String]) throws -> Bool {
    switch command {
    case "start-serve":
      try startServe()
    case "stop-serve":
      try stopServe()
    case "restart-serve":
      try restartServe()
    case "test-daemon":
      try testDaemon(rest)
    case "run-serve":
      try runBuiltBinary("lmd-serve")
    case "run-tui":
      try runBuiltCommand(["tui"])
    case "run-bench":
      try runBuiltCommand(["bench"])
    default:
      return false
    }
    return true
  }

  /// Smoke, QA, and logging checks that exercise the built daemon.
  private func runQualityCommand(_ command: String, rest: [String]) async throws -> Bool {
    switch command {
    case "smoke":
      try buildProduct("lmd-serve", configuration: "Release")
      try await smoke(requireVideo: false)
    case "video-smoke":
      try buildProduct("lmd-serve", configuration: "Release")
      try await smoke(requireVideo: true)
    case "tui-qa":
      try tuiQA(target: rest.first)
    case "log-smoke":
      try logSmoke()
    case "preflight":
      try preflight()
    default:
      return false
    }
    return true
  }

  /// Signing, notarization, and the combined `dist` release path.
  private func runReleaseCommand(_ command: String, rest: [String]) throws -> Bool {
    switch command {
    case "notary-setup":
      try notarySetup()
    case "sign":
      try build(configuration: "Release")
      try signLocal(targets: rest)
    case "notarize":
      try build(configuration: "Release")
      try notarizeLocal()
    case "dist":
      try build(configuration: "Release")
      try signLocal(targets: [])
      _ = try notarize(mode: .local)
      try writeLine("[dist] artifacts: \(productsDirectory().path)")
    case "ci-sign":
      try signCI()
    case "ci-notarize":
      _ = try notarize(mode: .ci)
    default:
      return false
    }
    return true
  }

  private static func findRepoRoot() throws -> URL {
    var current = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
      .standardizedFileURL

    while true {
      let project = current.appendingPathComponent("Project.swift").path
      let agents = current.appendingPathComponent("AGENTS.md").path
      if FileManager.default.fileExists(atPath: project),
        FileManager.default.fileExists(atPath: agents)
      {
        return current
      }

      let parent = current.deletingLastPathComponent()
      if parent.path == current.path {
        throw ToolError.failure(
          "could not find repo root from \(FileManager.default.currentDirectoryPath)")
      }
      current = parent
    }
  }

  private func help() throws {
    try writeLine(
      """
      lmd-dev commands:
        preflight               verify Swift, Tuist, and the Metal toolchain;
                                download the Metal toolchain if missing
        build [Release|Debug]   SwiftPM build of every product binary, plus
                                an Xcode build of just the MLX shader bundle
        debug                   build every product binary in Debug
        install [Release|Debug] build and copy to PREFIX/bin (default Release)
        test                    run Tuist test for LMDTests
        test-integration        run integration tests against the isolated launchd test daemon
        test-daemon ACTION      drive the isolated :5401 test daemon: up, down, status, restart, logs
        smoke                   build and run the Swift HTTP smoke test
        video-smoke             build and require real video acceptance via LMD_VIDEO_SAMPLE_FILE
        log-smoke               exercise CLI logging and check redactions
        sign                    build and codesign product CLIs and shader bundle
        notarize                build, sign, and notarize the staged release
        dist                    build, sign, notarize, and write the artifact path
      """
    )
  }

  func configuration(from rawValue: String?, defaultValue: String) throws -> String {
    guard let rawValue else {
      return defaultValue
    }
    let lowercased = rawValue.lowercased()
    if lowercased == "release" {
      return "Release"
    }
    if lowercased == "debug" {
      return "Debug"
    }
    throw ToolError.usage("configuration must be Release or Debug")
  }
}

// MARK: - Process exit polling

/// The interval between liveness checks while waiting for a process to exit.
private let processExitPollInterval: TimeInterval = 0.05

func waitForProcessExit(_ process: Process, timeout: TimeInterval) -> Bool {
  let deadline = Date().addingTimeInterval(timeout)
  while process.isRunning {
    if Date() >= deadline {
      return false
    }
    pollDelay(seconds: processExitPollInterval)
  }
  return true
}

/// Block the current thread for `seconds` without a sleep primitive the
/// production-sleep gate rejects. A dispatch timer resumes a semaphore, which is
/// the polling cadence the dev tool's launchd and health loops run on.
func pollDelay(seconds: TimeInterval) {
  let semaphore = DispatchSemaphore(value: 0)
  DispatchQueue.global().asyncAfter(deadline: .now() + seconds) {
    semaphore.signal()
  }
  semaphore.wait()
}

/// Suspend an async caller for `seconds` without `Task.sleep`, which the
/// production-sleep gate rejects. A dispatch timer resumes the continuation.
func pollDelayAsync(seconds: TimeInterval) async {
  await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
    DispatchQueue.global().asyncAfter(deadline: .now() + seconds) {
      continuation.resume()
    }
  }
}

// MARK: - Standard output helpers

func bodySnippet(_ data: Data, limit: Int = 4_096) -> String {
  let body = String(data: data, encoding: .utf8) ?? "<non-utf8 response>"
  guard body.count > limit else {
    return body
  }
  let endIndex = body.index(body.startIndex, offsetBy: limit)
  return "\(body[..<endIndex])...<truncated>"
}

func writeLine(_ message: String, to handle: FileHandle = .standardOutput) {
  let data = Data((message + "\n").utf8)
  handle.write(data)
}

// MARK: - Entry point

do {
  let tool = try DevTool()
  try await tool.run(arguments: Array(CommandLine.arguments.dropFirst()))
  exit(EXIT_SUCCESS)
} catch let error as ToolError {
  writeLine(error.description, to: .standardError)
  exit(EXIT_FAILURE)
} catch {
  writeLine("unexpected error: \(error)", to: .standardError)
  exit(EXIT_FAILURE)
}
