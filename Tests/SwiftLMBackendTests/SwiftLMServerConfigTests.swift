//
//  SwiftLMServerConfigTests.swift
//  SwiftLMBackendTests
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-04-18.
//  Copyright © 2026, all rights reserved.
//

import Foundation
import Nimble
import XCTest

@testable import SwiftLMBackend

final class SwiftLMServerConfigTests: XCTestCase {
  func testConfigDefaults() {
    let c = SwiftLMServerConfig(binaryPath: "/usr/bin/true")
    expect(c.host) == "localhost"
    expect(c.port) == 5_413
    expect(c.logFilePath) == nil
    expect(c.readyTimeout) == 300
  }

  func testConfigPreservesCustomValues() {
    let c = SwiftLMServerConfig(
      binaryPath: "/tmp/swiftlm",
      host: "[::1]",
      port: 5_500,
      logFilePath: "/tmp/swiftlm.log",
      readyTimeout: 120
    )
    expect(c.binaryPath) == "/tmp/swiftlm"
    expect(c.host) == "[::1]"
    expect(c.port) == 5_500
    expect(c.logFilePath) == "/tmp/swiftlm.log"
    expect(c.readyTimeout) == 120
  }

  func testStartThrowsWhenBinaryMissing() {
    let server = SwiftLMServer(
      model: "/tmp/nonexistent",
      config: SwiftLMServerConfig(binaryPath: "/definitely/does/not/exist/swiftlm")
    )
    expect { try server.start() }
      .to(throwError(SwiftLMServerError.binaryNotFound("/definitely/does/not/exist/swiftlm")))
    expect(server.isRunning) == false
  }

  func testStartCreatesMissingLogDirectory() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("lmd-swiftlm-server-tests-\(UUID().uuidString)")
    defer {
      try? FileManager.default.removeItem(at: directory)
    }
    let logPath =
      directory
      .appendingPathComponent("nested")
      .appendingPathComponent("swiftlm.log")
      .path
    let server = SwiftLMServer(
      model: "/tmp/model",
      config: SwiftLMServerConfig(
        binaryPath: "/usr/bin/true",
        logFilePath: logPath
      )
    )

    try server.start()
    server.stop()

    expect(FileManager.default.fileExists(atPath: logPath)) == true
  }
}
