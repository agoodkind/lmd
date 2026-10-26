//
//  ServiceProbeTests.swift
//  LMDDevTests
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-10-25.
//  Copyright © 2026, all rights reserved.
//

import AppLogger
import Foundation
import Nimble
import SwiftMkCore
import XCTest

@testable import lmd_dev

private let log = AppLogger.logger(category: "ServiceProbeTests")

// MARK: - Bounded production service probe

final class ServiceProbeTests: XCTestCase {
  private static let workerEnvironmentKey = "LMD_DEV_SERVICE_PROBE_WORKER"
  private static let workerTimeoutSeconds: Double = 10
  private static let minimumOutputBytes = 64 * 1_024
  private static let fixturePayloadBytes = 256 * 1_024
  private static let fixturePayload =
    "SERVICE_PROBE_BEGIN" + String(repeating: "P", count: fixturePayloadBytes) + "SERVICE_PROBE_END"

  func testLargeLaunchctlOutputCompletes() throws {
    AppLogger.bootstrap(subsystem: "io.goodkind.lmd")
    if let target = ProcessInfo.processInfo.environment[Self.workerEnvironmentKey] {
      try probeFixture(target)
      return
    }
    let target = try bootstrapFixture()
    let bundle = Bundle(for: Self.self).bundleURL
    let result = Shell.runForwardingAndCapturingStreaming(
      "/usr/bin/xcrun",
      [
        "xctest", "-XCTest", "LMDDevTests.ServiceProbeTests/testLargeLaunchctlOutputCompletes",
        bundle.path,
      ],
      environment: [Self.workerEnvironmentKey: target],
      timeoutSeconds: Self.workerTimeoutSeconds)
    expect(result.timedOut).to(
      beFalse(), description: "The service probe did not finish before its deadline.")
    expect(result.status).to(equal(0), description: result.combined)
    expect(result.combined).to(contain("Executed 1 test"))
  }

  private func probeFixture(_ target: String) throws {
    let output = Shell.run("/bin/launchctl", ["print", target])
    expect(output.status).to(equal(0), description: "The temporary launchd job must be readable.")
    expect(output.stdout.utf8.count) > Self.minimumOutputBytes
    expect(output.stdout.contains(Self.fixturePayload)) == true
    expect(output.stdout).to(contain("state = not running"))
    expect(output.stdout).to(contain("runs = 0"))
    log.notice("service.probe_output bytes=\(output.stdout.utf8.count, privacy: .public)")
    let tool = try DevTool()
    expect(tool.isServiceLoaded(target)) == true
  }

  private func bootstrapFixture() throws -> String {
    let label = "io.goodkind.lmd.service-probe." + UUID().uuidString.lowercased()
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(label)
    log.notice("service.fixture_create label=\(label, privacy: .public)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    addTeardownBlock {
      log.notice("service.fixture_remove path=\(directory.path, privacy: .public)")
      try FileManager.default.removeItem(at: directory)
    }
    let job = ServiceProbeJob(
      label: label, environmentVariables: ["LMD_SERVICE_PROBE_PAYLOAD": Self.fixturePayload])
    let plist = directory.appendingPathComponent("fixture.plist")
    let encoder = PropertyListEncoder()
    encoder.outputFormat = .xml
    try encoder.encode(job).write(to: plist)
    let domain = "user/\(getuid())"
    let target = domain + "/" + label
    let result = Shell.run("/bin/launchctl", ["bootstrap", domain, plist.path])
    guard result.status == 0 else {
      throw ToolError.failure(
        "Temporary launchd job bootstrap failed (\(result.status)): \(result.stderr)")
    }
    addTeardownBlock {
      log.notice("service.fixture_bootout target=\(target, privacy: .public)")
      let cleanup = Shell.run("/bin/launchctl", ["bootout", target])
      guard cleanup.status == 0 else {
        throw ToolError.failure(
          "Temporary launchd job cleanup failed (\(cleanup.status)): \(cleanup.stderr)")
      }
    }
    return target
  }
}

// MARK: - Stopped Background user-domain fixture

private struct ServiceProbeJob: Encodable {
  let label: String
  let programArguments = ["/usr/bin/true"]
  let runAtLoad = false
  let keepAlive = false
  let limitLoadToSessionType = "Background"
  let environmentVariables: [String: String]

  enum CodingKeys: String, CodingKey {
    case label = "Label"
    case programArguments = "ProgramArguments"
    case runAtLoad = "RunAtLoad"
    case keepAlive = "KeepAlive"
    case limitLoadToSessionType = "LimitLoadToSessionType"
    case environmentVariables = "EnvironmentVariables"
  }
}
