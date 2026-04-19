//
//  SwiftLMServerConfigTests.swift
//  SwiftLMBackendTests
//
//  Created by Alex Goodkind <alex@goodkind.io> on 2026-04-18.
//  Copyright © 2026
//

import XCTest
@testable import SwiftLMBackend

final class SwiftLMServerConfigTests: XCTestCase {
  func testConfigDefaults() {
    let c = SwiftLMServerConfig(binaryPath: "/usr/bin/true")
    XCTAssertEqual(c.host, "127.0.0.1")
    XCTAssertEqual(c.port, 5413)
    XCTAssertNil(c.logFilePath)
    XCTAssertEqual(c.readyTimeout, 300)
  }

  func testConfigPreservesCustomValues() {
    let c = SwiftLMServerConfig(
      binaryPath: "/tmp/swiftlm",
      host: "0.0.0.0",
      port: 5500,
      logFilePath: "/tmp/swiftlm.log",
      readyTimeout: 120
    )
    XCTAssertEqual(c.binaryPath, "/tmp/swiftlm")
    XCTAssertEqual(c.host, "0.0.0.0")
    XCTAssertEqual(c.port, 5500)
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
}
