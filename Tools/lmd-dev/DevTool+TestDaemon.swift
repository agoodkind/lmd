//
//  DevTool+TestDaemon.swift
//  lmd-dev
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-05-10.
//  Copyright © 2026, all rights reserved.
//

import Foundation
import SwiftMkCore

/// The production daemon port the isolated test daemon must never collide with.
private let productionDaemonPort = 5_400
/// The default isolated test daemon port.
private let defaultTestDaemonPort = 5_401
/// How long to wait for the test daemon to report healthy, in seconds.
private let testHealthTimeoutSeconds = 30
/// The interval between test daemon `/health` probes, in seconds.
private let testHealthPollInterval: TimeInterval = 1
/// The per-probe `/health` curl timeout, in seconds.
private let testHealthRequestTimeoutSeconds = "2"
/// How many trailing stderr lines to print when an `up` never becomes healthy.
private let testStderrTailLineCount = 20
/// Default battery thresholds that disable the PowerMonitor for the test daemon.
private let testBatteryThrottleDefault = "0"
private let testBatteryMildDefault = "1"
private let testBatteryResumeDefault = "2"
/// Default OTLP export settings for the test daemon plist.
private let testOTLPProtocolDefault = "grpc"
private let testOTLPMetricIntervalDefault = "2000"

// MARK: - TestDaemonIdentity

/// Resolved identity for the isolated test daemon. Distinct launchd label,
/// Mach service pair, port, and data dir keep it from ever colliding with the
/// production daemon on :5400. The render inputs (serve binary, SwiftLM binary)
/// resolve separately in `testDaemonUp`, so down/status/restart/logs work even
/// when no build is staged.
struct TestDaemonIdentity {
  let port: Int
  let label: String
  let controlService: String
  let hostService: String
  let dataDir: URL
  let workDir: URL
  let stderrLog: URL
  let renderedPlist: URL

  var domain: String { "gui/\(getuid())" }
  var serviceTarget: String { "\(domain)/\(label)" }
  var healthURL: String { "http://localhost:\(port)/health" }
}

// MARK: - Test daemon control

extension DevTool {
  func testDaemon(_ arguments: [String]) throws {
    guard let action = arguments.first else {
      throw ToolError.usage("usage: test-daemon {up|down|status|restart|logs}")
    }
    switch action {
    case "up":
      try testDaemonUp()
    case "down":
      try testDaemonDown()
    case "status":
      try testDaemonStatus()
    case "restart":
      try testDaemonRestart()
    case "logs":
      try testDaemonLogs()
    default:
      throw ToolError.usage(
        "unknown test-daemon action: \(action) (try: up, down, status, restart, logs)")
    }
  }

  /// Resolve the test daemon identity from the environment overrides. The
  /// isolation guard refuses to run if the test port or label equals production,
  /// the single safeguard that keeps :5400 untouched.
  private func resolveTestDaemonIdentity() throws -> TestDaemonIdentity {
    let env = environment.values
    let label = env["LMD_TEST_LABEL"] ?? "io.goodkind.lmd.serve.test"
    let port = Int(env["LMD_TEST_PORT"] ?? String(defaultTestDaemonPort)) ?? defaultTestDaemonPort
    guard port != productionDaemonPort else {
      throw ToolError.failure(
        "refusing: test port equals production port \(productionDaemonPort)")
    }
    guard label != "io.goodkind.lmd.serve" else {
      throw ToolError.failure("refusing: test label equals production label io.goodkind.lmd.serve")
    }
    let dataDir: URL
    if let override = env["LMD_TEST_DATA_DIR"], !override.isEmpty {
      dataDir = URL(fileURLWithPath: override).standardizedFileURL
    } else {
      dataDir = repoRoot.appendingPathComponent(".claude/tmp/lmd-test/data")
    }
    let workDir = dataDir.deletingLastPathComponent()
    return TestDaemonIdentity(
      port: port,
      label: label,
      controlService: "io.goodkind.lmd.control.test",
      hostService: "io.goodkind.lmd.host.test",
      dataDir: dataDir,
      workDir: workDir,
      stderrLog: workDir.appendingPathComponent("lmd-serve.test.stderr.log"),
      renderedPlist: workDir.appendingPathComponent("\(label).plist")
    )
  }

  /// Prefer a Release build, fall back to Debug. The model host must sit beside
  /// the broker binary, since the broker resolves it as a sibling at spawn time.
  private func resolveTestServeBinary() throws -> URL {
    for configuration in ["Release", "Debug"] {
      let candidate = buildDirectory(configuration: configuration)
        .appendingPathComponent("lmd-serve")
      if fileManager.isExecutableFile(atPath: candidate.path) {
        let host = candidate.deletingLastPathComponent().appendingPathComponent("lmd-model-host")
        guard fileManager.isExecutableFile(atPath: host.path) else {
          throw ToolError.failure(
            "found \(candidate.path) but no sibling lmd-model-host; run 'make build' first")
        }
        return candidate
      }
    }
    throw ToolError.failure(
      "no built lmd-serve under \(productsDirectory().appendingPathComponent("Build").path); run 'make build'"
    )
  }

  /// The broker checks LMD_SWIFTLM_BINARY is executable at boot even for
  /// embedding and video tests, so it must resolve to a real file. Read it from
  /// the installed production plist by default so the harness is self-configuring.
  private func resolveTestSwiftLMBinary() throws -> String {
    if let value = environment.values["LMD_SWIFTLM_BINARY"], !value.isEmpty {
      return value
    }
    let prodPlist = homeDirectory()
      .appendingPathComponent("Library/LaunchAgents/io.goodkind.lmd.serve.plist")
    if fileManager.fileExists(atPath: prodPlist.path),
      let value = plistBuddyValue(":EnvironmentVariables:LMD_SWIFTLM_BINARY", in: prodPlist)
    {
      return value
    }
    throw ToolError.failure(
      "set LMD_SWIFTLM_BINARY, or install the production plist so it can be read")
  }

  /// Read one entry from a plist via PlistBuddy, returning nil when the key is
  /// absent. Runs PlistBuddy directly rather than through `runCaptured` so a
  /// missing key never prints its error to the terminal.
  private func plistBuddyValue(_ entry: String, in plist: URL) -> String? {
    Output.debug("plistBuddyValue entry=\(entry) plist=\(plist.path)")
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/libexec/PlistBuddy")
    process.arguments = ["-c", "Print \(entry)", plist.path]
    let out = Pipe()
    let err = Pipe()
    process.standardOutput = out
    process.standardError = err
    do {
      try process.run()
    } catch {
      Output.notice("plistBuddyValue launch failed entry=\(entry) error=\(error)")
      return nil
    }
    process.waitUntilExit()
    _ = err.fileHandleForReading.readDataToEndOfFile()
    let data = out.fileHandleForReading.readDataToEndOfFile()
    guard process.terminationStatus == 0 else {
      return nil
    }
    let value = String(data: data, encoding: .utf8)?
      .trimmingCharacters(in: .whitespacesAndNewlines)
    if let value, !value.isEmpty {
      return value
    }
    return nil
  }

  /// Fill the test plist template's placeholders. Battery thresholds default
  /// to 0/1/2, which disables the PowerMonitor so the hard admission halt never
  /// refuses a request on battery. An empty OTLP endpoint leaves export disabled.
  private func renderTestPlist(
    identity: TestDaemonIdentity, template: URL, servePath: URL, swiftLMBinary: String
  ) throws {
    Output.debug("renderTestPlist label=\(identity.label) plist=\(identity.renderedPlist.path)")
    let env = environment.values
    var contents = try String(contentsOf: template, encoding: .utf8)
    let substitutions: [(String, String)] = [
      ("{{LABEL}}", identity.label),
      ("{{CONTROL_SERVICE}}", identity.controlService),
      ("{{HOST_SERVICE}}", identity.hostService),
      ("{{LMD_SERVE_PATH}}", servePath.path),
      ("{{LMD_PORT}}", String(identity.port)),
      ("{{LMD_DATA_DIR}}", identity.dataDir.path),
      ("{{LMD_SWIFTLM_BINARY}}", swiftLMBinary),
      ("{{STDERR_LOG}}", identity.stderrLog.path),
      (
        "{{LMD_BATTERY_THROTTLE_PCT}}",
        env["LMD_TEST_BATTERY_THROTTLE_PCT"]
          ?? testBatteryThrottleDefault
      ),
      ("{{LMD_BATTERY_MILD_PCT}}", env["LMD_TEST_BATTERY_MILD_PCT"] ?? testBatteryMildDefault),
      (
        "{{LMD_BATTERY_RESUME_PCT}}",
        env["LMD_TEST_BATTERY_RESUME_PCT"]
          ?? testBatteryResumeDefault
      ),
      ("{{OTEL_EXPORTER_OTLP_ENDPOINT}}", env["OTEL_EXPORTER_OTLP_ENDPOINT"] ?? ""),
      (
        "{{OTEL_EXPORTER_OTLP_PROTOCOL}}",
        env["OTEL_EXPORTER_OTLP_PROTOCOL"]
          ?? testOTLPProtocolDefault
      ),
      (
        "{{OTEL_METRIC_EXPORT_INTERVAL}}",
        env["OTEL_METRIC_EXPORT_INTERVAL"]
          ?? testOTLPMetricIntervalDefault
      ),
    ]
    for (placeholder, value) in substitutions {
      contents = contents.replacingOccurrences(of: placeholder, with: value)
    }
    try contents.write(to: identity.renderedPlist, atomically: true, encoding: .utf8)
  }

  /// Probe `/health` once. Runs curl directly so a non-200 never throws or
  /// prints; the caller polls on the boolean.
  private func probeTestHealth(_ identity: TestDaemonIdentity) -> Bool {
    Output.debug("probeTestHealth url=\(identity.healthURL)")
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
    process.arguments = [
      "-fsS", "-o", "/dev/null", "--max-time", testHealthRequestTimeoutSeconds, identity.healthURL,
    ]
    let sink = Pipe()
    process.standardOutput = sink
    process.standardError = sink
    do {
      try process.run()
    } catch {
      Output.notice("probeTestHealth launch failed url=\(identity.healthURL) error=\(error)")
      return false
    }
    process.waitUntilExit()
    _ = sink.fileHandleForReading.readDataToEndOfFile()
    return process.terminationStatus == 0
  }

  private func waitTestHealth(
    _ identity: TestDaemonIdentity, timeoutSeconds: Int = testHealthTimeoutSeconds
  ) -> Bool {
    let deadline = Date().addingTimeInterval(TimeInterval(timeoutSeconds))
    while Date() < deadline {
      if probeTestHealth(identity) {
        return true
      }
      pollDelay(seconds: testHealthPollInterval)
    }
    return false
  }

  /// Print the last `lines` of the test daemon stderr log, best effort, so a
  /// failed `up` surfaces why the daemon never became healthy.
  private func printTestStderr(_ log: URL, lines: Int = testStderrTailLineCount) {
    let contents: String
    do {
      contents = try String(contentsOf: log, encoding: .utf8)
    } catch {
      Output.notice("printTestStderr read failed log=\(log.path) error=\(error)")
      return
    }
    let all = contents.split(separator: "\n", omittingEmptySubsequences: false)
    for line in all.suffix(lines) {
      do {
        try writeLine(String(line))
      } catch {
        Output.warning("printTestStderr write failed error=\(error)")
      }
    }
  }

  func testDaemonUp() throws {
    Output.debug("testDaemonUp")
    let identity = try resolveTestDaemonIdentity()
    let servePath = try resolveTestServeBinary()
    let swiftLMBinary = try resolveTestSwiftLMBinary()
    guard fileManager.isExecutableFile(atPath: swiftLMBinary) else {
      throw ToolError.failure("LMD_SWIFTLM_BINARY not executable: \(swiftLMBinary)")
    }
    let template = repoRoot.appendingPathComponent(
      "deploy/io.goodkind.lmd.serve.test.plist.template")
    guard fileManager.fileExists(atPath: template.path) else {
      throw ToolError.failure("missing template: \(template.path)")
    }

    try fileManager.createDirectory(at: identity.dataDir, withIntermediateDirectories: true)
    try renderTestPlist(
      identity: identity, template: template, servePath: servePath, swiftLMBinary: swiftLMBinary)

    // Replace any prior instance so a stale agent never lingers. The bootout
    // returns before launchd drops the label, so poll until it is gone before
    // bootstrapping, the same race the production startServe guards against.
    if isServiceLoaded(identity.serviceTarget) {
      bootoutBestEffort(identity.serviceTarget)
      waitForServiceUnload(identity.serviceTarget, timeoutSeconds: serviceUnloadTimeoutSeconds)
    }
    try writeLine("  bootstrapping \(identity.label) on :\(identity.port)")
    try writeLine("    serve   = \(servePath.path)")
    try writeLine("    data    = \(identity.dataDir.path)")
    try writeLine("    swiftlm = \(swiftLMBinary)")
    try runPassthrough("launchctl", ["bootstrap", identity.domain, identity.renderedPlist.path])

    if waitTestHealth(identity) {
      try writeLine("  healthy at \(identity.healthURL)")
      return
    }
    try writeLine("  health timed out; recent stderr from \(identity.stderrLog.path):")
    printTestStderr(identity.stderrLog)
    throw ToolError.failure("test daemon did not become healthy")
  }

  func testDaemonDown() throws {
    Output.debug("testDaemonDown")
    let identity = try resolveTestDaemonIdentity()
    try writeLine("  booting out \(identity.label)")
    bootoutBestEffort(identity.serviceTarget)
    removeItemBestEffort(identity.renderedPlist)
    if environment.values["LMD_TEST_KEEP_DATA"] == "1" {
      try writeLine("  keeping data dir \(identity.dataDir.path)")
    } else {
      removeItemBestEffort(identity.dataDir)
    }
    try writeLine("  down")
  }

  func testDaemonStatus() throws {
    Output.debug("testDaemonStatus")
    let identity = try resolveTestDaemonIdentity()
    try writeLine("=== health \(identity.healthURL) ===")
    try writeLine(probeTestHealth(identity) ? "healthy" : "(unreachable)")
    try writeLine("=== launchctl print \(identity.serviceTarget) ===")
    do {
      try runPassthrough("launchctl", ["print", identity.serviceTarget])
    } catch {
      Output.notice(
        "testDaemonStatus print failed service=\(identity.serviceTarget) error=\(error)")
      try writeLine("(not loaded)")
    }
  }

  func testDaemonRestart() throws {
    Output.debug("testDaemonRestart")
    let identity = try resolveTestDaemonIdentity()
    try writeLine("  kickstart -k \(identity.serviceTarget)")
    try runPassthrough("launchctl", ["kickstart", "-k", identity.serviceTarget])
    if waitTestHealth(identity) {
      try writeLine("  healthy at \(identity.healthURL)")
      return
    }
    throw ToolError.failure("test daemon did not become healthy after restart")
  }

  func testDaemonLogs() throws {
    Output.debug("testDaemonLogs")
    let identity = try resolveTestDaemonIdentity()
    guard fileManager.fileExists(atPath: identity.stderrLog.path) else {
      throw ToolError.failure("no log at \(identity.stderrLog.path)")
    }
    let lines = environment.values["LMD_TEST_LOG_LINES"] ?? "50"
    try runPassthrough("tail", ["-n", lines, "-f", identity.stderrLog.path])
  }

  /// Remove a path, logging rather than throwing so a teardown step never masks
  /// the real outcome of the command that called it.
  private func removeItemBestEffort(_ url: URL) {
    do {
      try removeIfExists(url)
    } catch {
      Output.warning("removeItem best-effort failed path=\(url.path) error=\(error)")
    }
  }
}
