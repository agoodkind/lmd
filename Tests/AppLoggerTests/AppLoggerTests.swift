//
//  AppLoggerTests.swift
//  AppLoggerTests
//
//  Created by Alex Goodkind <alex@goodkind.io> on 2026-04-18.
//  Copyright © 2026
//

import XCTest
@testable import AppLogger

final class AppLoggerTests: XCTestCase {
  func testBootstrapIsIdempotent() {
    // Calling twice must not throw and must not crash. os.Logger has no
    // way for us to introspect the stored subsystem externally, so this
    // is a liveness check: the static queue guards must not deadlock or
    // panic on second entry.
    AppLogger.bootstrap(subsystem: "io.goodkind.lmd")
    AppLogger.bootstrap(subsystem: "io.goodkind.lmd")
  }

  func testLoggerReturnsUsableHandle() {
    AppLogger.bootstrap(subsystem: "io.goodkind.lmd")
    let log = AppLogger.logger(category: "Test")
    // Emitting must not throw; the message lands in the unified logging
    // system regardless of whether a viewer is attached.
    log.notice("test.event kind=\("liveness", privacy: .public)")
  }

  func testSignposterReturnsUsableHandle() {
    AppLogger.bootstrap(subsystem: "io.goodkind.lmd")
    let sp = AppLogger.signposter()
    let state = sp.beginInterval("test.span")
    sp.endInterval("test.span", state)
  }
}
