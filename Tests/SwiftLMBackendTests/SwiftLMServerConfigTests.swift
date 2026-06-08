//
//  SwiftLMServerConfigTests.swift
//  SwiftLMBackendTests
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-04-18.
//  Copyright © 2026, all rights reserved.
//

import Foundation
import XCTest

@testable import SwiftLMBackend

final class SwiftLMServerConfigTests: XCTestCase {
  func testConfigDefaults() {
    let c = SwiftLMServerConfig(binaryPath: "/usr/bin/true")
    XCTAssertEqual(c.host, "localhost")
    XCTAssertEqual(c.port, 5_413)
    XCTAssertNil(c.logFilePath)
    XCTAssertEqual(c.readyTimeout, 300)
  }

  func testConfigPreservesCustomValues() {
    let c = SwiftLMServerConfig(
      binaryPath: "/tmp/swiftlm",
      host: "[::1]",
      port: 5_500,
      logFilePath: "/tmp/swiftlm.log",
      readyTimeout: 120
    )
    XCTAssertEqual(c.binaryPath, "/tmp/swiftlm")
    XCTAssertEqual(c.host, "[::1]")
    XCTAssertEqual(c.port, 5_500)
    XCTAssertEqual(c.logFilePath, "/tmp/swiftlm.log")
    XCTAssertEqual(c.readyTimeout, 120)
  }

  func testStartThrowsWhenBinaryMissing() {
    let server = SwiftLMServer(
      model: "/tmp/nonexistent",
      config: SwiftLMServerConfig(binaryPath: "/definitely/does/not/exist/swiftlm")
    )
    XCTAssertThrowsError(try server.start()) { error in
      if case SwiftLMServerError.binaryNotFound(let path) = error {
        XCTAssertEqual(path, "/definitely/does/not/exist/swiftlm")
      } else {
        XCTFail("expected .binaryNotFound, got \(error)")
      }
    }
    XCTAssertFalse(server.isRunning)
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

    XCTAssertTrue(FileManager.default.fileExists(atPath: logPath))
  }
}
