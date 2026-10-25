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

final class ServiceProbeTests: XCTestCase {
  private static let workerEnvironmentKey = "LMD_DEV_SERVICE_PROBE_WORKER"
  private static let workerTimeoutSeconds: Double = 10
  private static let minimumOutputBytes = 64 * 1_024

  func testLargeLaunchctlOutputCompletes() throws {
    AppLogger.bootstrap(subsystem: "io.goodkind.lmd")
    if ProcessInfo.processInfo.environment[Self.workerEnvironmentKey] == "1" {
      let output = Shell.run("/bin/launchctl", ["print", "system"])
      expect(output.status).to(equal(0), description: "The system launchd domain must be readable.")
      expect(output.stdout.utf8.count) > Self.minimumOutputBytes
      log.notice("service.probe_output bytes=\(output.stdout.utf8.count, privacy: .public)")
      let tool = try DevTool()
      expect(tool.isServiceLoaded("system")) == true
      return
    }

    let bundle = Bundle(for: Self.self).bundleURL
    let result = Shell.runForwardingAndCapturingStreaming(
      "/usr/bin/xcrun",
      [
        "xctest", "-XCTest", "LMDDevTests.ServiceProbeTests/testLargeLaunchctlOutputCompletes",
        bundle.path,
      ],
      environment: [Self.workerEnvironmentKey: "1"],
      timeoutSeconds: Self.workerTimeoutSeconds)
    expect(result.timedOut).to(
      beFalse(), description: "The service probe did not finish before its deadline.")
    expect(result.status).to(equal(0), description: result.combined)
    expect(result.combined).to(contain("Executed 1 test"))
  }
}
