//
//  PowerMonitorTests.swift
//  SwiftLMMonitorTests
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-06-04.
//  Copyright © 2026, all rights reserved.
//

import XCTest

@testable import SwiftLMMonitor

final class PowerMonitorLevelTests: XCTestCase {
  private func config(engagePct: Int = 20, resumePct: Int = 80) -> PowerMonitor.Config {
    PowerMonitor.Config(engagePct: engagePct, resumePct: resumePct, intervalSeconds: 15)
  }

  func testEngagesAtOrBelowEngageThreshold() {
    XCTAssertEqual(PowerMonitor.nextLevel(percent: 20, config: config(), previous: .none), .hard)
    XCTAssertEqual(PowerMonitor.nextLevel(percent: 12, config: config(), previous: .none), .hard)
  }

  func testDoesNotEngageJustAboveThreshold() {
    XCTAssertEqual(PowerMonitor.nextLevel(percent: 21, config: config(), previous: .none), .none)
  }

  func testReleasesAtOrAboveResumeThreshold() {
    XCTAssertEqual(PowerMonitor.nextLevel(percent: 80, config: config(), previous: .hard), .none)
    XCTAssertEqual(PowerMonitor.nextLevel(percent: 95, config: config(), previous: .hard), .none)
  }

  func testHoldsThrottleThroughTheBandWhileRecharging() {
    // Engaged at 20, then charging climbs through the band: stays hard until 80.
    var level = PowerMonitor.Level.hard
    for percent in stride(from: 21, through: 79, by: 1) {
      level = PowerMonitor.nextLevel(percent: percent, config: config(), previous: level)
      XCTAssertEqual(level, .hard, "should hold hard at \(percent)%")
    }
    level = PowerMonitor.nextLevel(percent: 80, config: config(), previous: level)
    XCTAssertEqual(level, .none, "should release at 80%")
  }

  func testHoldsOffThroughTheBandWhileDraining() {
    // Released at 80, then draining falls through the band: stays off until 20.
    var level = PowerMonitor.Level.none
    for percent in stride(from: 79, through: 21, by: -1) {
      level = PowerMonitor.nextLevel(percent: percent, config: config(), previous: level)
      XCTAssertEqual(level, .none, "should hold off at \(percent)%")
    }
    level = PowerMonitor.nextLevel(percent: 20, config: config(), previous: level)
    XCTAssertEqual(level, .hard, "should engage at 20%")
  }

  func testNoFlapWhenHoveringInsideBand() {
    // A charge oscillating mid-band never changes the level.
    var level = PowerMonitor.Level.hard
    for percent in [40, 55, 40, 55, 41, 54, 50] {
      level = PowerMonitor.nextLevel(percent: percent, config: config(), previous: level)
    }
    XCTAssertEqual(level, .hard, "mid-band hovering must not flap")
  }

  func testNoFlapHoveringAtEngageThreshold() {
    // Once engaged at 20, hovering 20/21 stays hard (does not release until 80).
    var level = PowerMonitor.Level.none
    for percent in [20, 21, 20, 22, 21, 20] {
      level = PowerMonitor.nextLevel(percent: percent, config: config(), previous: level)
    }
    XCTAssertEqual(level, .hard)
  }

  func testDisabledWhenEngageIsZero() {
    let cfg = config(engagePct: 0, resumePct: 80)
    XCTAssertTrue(cfg.isDisabled)
  }
}
