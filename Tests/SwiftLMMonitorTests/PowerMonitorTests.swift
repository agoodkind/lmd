//
//  PowerMonitorTests.swift
//  SwiftLMMonitorTests
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-06-04.
//  Copyright © 2026, all rights reserved.
//

import Nimble
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
    expect(PowerMonitor.nextLevel(percent: 20, config: self.config(), previous: .none)) == .hard
    expect(PowerMonitor.nextLevel(percent: 12, config: self.config(), previous: .none)) == .hard
  }

  func testMildEngagesInsideTheBand() {
    expect(PowerMonitor.nextLevel(percent: 35, config: self.config(), previous: .none)) == .mild
    expect(PowerMonitor.nextLevel(percent: 30, config: self.config(), previous: .none)) == .mild
    expect(PowerMonitor.nextLevel(percent: 21, config: self.config(), previous: .none)) == .mild
  }

  func testNoneAboveMildThreshold() {
    expect(PowerMonitor.nextLevel(percent: 36, config: self.config(), previous: .none))
      == PowerMonitor.Level.none
    expect(PowerMonitor.nextLevel(percent: 50, config: self.config(), previous: .none))
      == PowerMonitor.Level.none
  }

  func testMildDoesNotHold() {
    // mild has no memory: above the mild threshold it turns off immediately.
    expect(PowerMonitor.nextLevel(percent: 36, config: self.config(), previous: .mild))
      == PowerMonitor.Level.none
    expect(PowerMonitor.nextLevel(percent: 50, config: self.config(), previous: .mild))
      == PowerMonitor.Level.none
  }

  func testHardHoldsThroughTheBandWhileRecharging() {
    // Engaged at 20, then charging climbs through the band: stays hard until 80.
    var level = PowerMonitor.Level.hard
    for percent in stride(from: 21, through: 79, by: 1) {
      level = PowerMonitor.nextLevel(percent: percent, config: self.config(), previous: level)
      expect(level) == .hard
    }
    level = PowerMonitor.nextLevel(percent: 80, config: self.config(), previous: level)
    expect(level) == PowerMonitor.Level.none
  }

  func testHardHoldOverridesMild() {
    // While hard is held, a charge inside the mild band stays hard, not mild.
    expect(PowerMonitor.nextLevel(percent: 30, config: self.config(), previous: .hard)) == .hard
    expect(PowerMonitor.nextLevel(percent: 25, config: self.config(), previous: .hard)) == .hard
  }

  func testReleasesAtOrAboveResumeThreshold() {
    expect(PowerMonitor.nextLevel(percent: 80, config: self.config(), previous: .hard))
      == PowerMonitor.Level.none
    expect(PowerMonitor.nextLevel(percent: 95, config: self.config(), previous: .hard))
      == PowerMonitor.Level.none
  }

  func testDrainingEscalatesNoneToMildToHard() {
    var level = PowerMonitor.Level.none
    for percent in stride(from: 79, through: 36, by: -1) {
      level = PowerMonitor.nextLevel(percent: percent, config: self.config(), previous: level)
      expect(level) == PowerMonitor.Level.none
    }
    for percent in stride(from: 35, through: 21, by: -1) {
      level = PowerMonitor.nextLevel(percent: percent, config: self.config(), previous: level)
      expect(level) == .mild
    }
    level = PowerMonitor.nextLevel(percent: 20, config: self.config(), previous: level)
    expect(level) == .hard
  }

  func testNoFlapHoveringAtEngageThreshold() {
    // Once hard engages at 20, hovering 20/21/22 stays hard until 80.
    var level = PowerMonitor.Level.none
    for percent in [20, 21, 20, 22, 21, 20] {
      level = PowerMonitor.nextLevel(percent: percent, config: self.config(), previous: level)
    }
    expect(level) == .hard
  }

  func testMildFollowsLiveChargeAtItsEdge() {
    // mild is a plain band by design, so it toggles at the 35% edge.
    var level = PowerMonitor.Level.none
    level = PowerMonitor.nextLevel(percent: 36, config: self.config(), previous: level)
    expect(level) == PowerMonitor.Level.none
    level = PowerMonitor.nextLevel(percent: 35, config: self.config(), previous: level)
    expect(level) == .mild
    level = PowerMonitor.nextLevel(percent: 36, config: self.config(), previous: level)
    expect(level) == PowerMonitor.Level.none
  }

  func testDisabledWhenEngageIsZero() {
    let cfg = self.config(engagePct: 0)
    expect(cfg.isDisabled) == true
  }
}
