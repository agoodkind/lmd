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
  private func config(
    engagePct: Int = 20,
    mildEngagePct: Int = 35,
    resumePct: Int = 80
  ) -> PowerMonitor.Config {
    PowerMonitor.Config(
      engagePct: engagePct,
      mildEngagePct: mildEngagePct,
      resumePct: resumePct,
      intervalSeconds: 15
    )
  }

  func testHardEngagesAtOrBelowEngageThreshold() {
    XCTAssertEqual(PowerMonitor.nextLevel(percent: 20, config: config(), previous: .none), .hard)
    XCTAssertEqual(PowerMonitor.nextLevel(percent: 12, config: config(), previous: .none), .hard)
  }

  func testMildEngagesInsideTheBand() {
    XCTAssertEqual(PowerMonitor.nextLevel(percent: 35, config: config(), previous: .none), .mild)
    XCTAssertEqual(PowerMonitor.nextLevel(percent: 30, config: config(), previous: .none), .mild)
    XCTAssertEqual(PowerMonitor.nextLevel(percent: 21, config: config(), previous: .none), .mild)
  }

  func testNoneAboveMildThreshold() {
    XCTAssertEqual(PowerMonitor.nextLevel(percent: 36, config: config(), previous: .none), .none)
    XCTAssertEqual(PowerMonitor.nextLevel(percent: 50, config: config(), previous: .none), .none)
  }

  func testMildDoesNotHold() {
    // mild has no memory: above the mild threshold it turns off immediately.
    XCTAssertEqual(PowerMonitor.nextLevel(percent: 36, config: config(), previous: .mild), .none)
    XCTAssertEqual(PowerMonitor.nextLevel(percent: 50, config: config(), previous: .mild), .none)
  }

  func testHardHoldsThroughTheBandWhileRecharging() {
    // Engaged at 20, then charging climbs through the band: stays hard until 80.
    var level = PowerMonitor.Level.hard
    for percent in stride(from: 21, through: 79, by: 1) {
      level = PowerMonitor.nextLevel(percent: percent, config: config(), previous: level)
      XCTAssertEqual(level, .hard, "should hold hard at \(percent)%")
    }
    level = PowerMonitor.nextLevel(percent: 80, config: config(), previous: level)
    XCTAssertEqual(level, .none, "should release at 80%")
  }

  func testHardHoldOverridesMild() {
    // While hard is held, a charge inside the mild band stays hard, not mild.
    XCTAssertEqual(PowerMonitor.nextLevel(percent: 30, config: config(), previous: .hard), .hard)
    XCTAssertEqual(PowerMonitor.nextLevel(percent: 25, config: config(), previous: .hard), .hard)
  }

  func testReleasesAtOrAboveResumeThreshold() {
    XCTAssertEqual(PowerMonitor.nextLevel(percent: 80, config: config(), previous: .hard), .none)
    XCTAssertEqual(PowerMonitor.nextLevel(percent: 95, config: config(), previous: .hard), .none)
  }

  func testDrainingEscalatesNoneToMildToHard() {
    var level = PowerMonitor.Level.none
    for percent in stride(from: 79, through: 36, by: -1) {
      level = PowerMonitor.nextLevel(percent: percent, config: config(), previous: level)
      XCTAssertEqual(level, .none, "should stay none at \(percent)%")
    }
    for percent in stride(from: 35, through: 21, by: -1) {
      level = PowerMonitor.nextLevel(percent: percent, config: config(), previous: level)
      XCTAssertEqual(level, .mild, "should be mild at \(percent)%")
    }
    level = PowerMonitor.nextLevel(percent: 20, config: config(), previous: level)
    XCTAssertEqual(level, .hard, "should engage hard at 20%")
  }

  func testNoFlapHoveringAtEngageThreshold() {
    // Once hard engages at 20, hovering 20/21/22 stays hard until 80.
    var level = PowerMonitor.Level.none
    for percent in [20, 21, 20, 22, 21, 20] {
      level = PowerMonitor.nextLevel(percent: percent, config: config(), previous: level)
    }
    XCTAssertEqual(level, .hard)
  }

  func testMildFollowsLiveChargeAtItsEdge() {
    // mild is a plain band by design, so it toggles at the 35% edge.
    var level = PowerMonitor.Level.none
    level = PowerMonitor.nextLevel(percent: 36, config: config(), previous: level)
    XCTAssertEqual(level, .none)
    level = PowerMonitor.nextLevel(percent: 35, config: config(), previous: level)
    XCTAssertEqual(level, .mild)
    level = PowerMonitor.nextLevel(percent: 36, config: config(), previous: level)
    XCTAssertEqual(level, .none)
  }

  func testDisabledWhenEngageIsZero() {
    let cfg = config(engagePct: 0)
    XCTAssertTrue(cfg.isDisabled)
  }
}
