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
    resumePct: Int = 80,
    highPowerOverride: Bool = true
  ) -> PowerMonitor.Config {
    PowerMonitor.Config(
      engagePct: engagePct,
      mildEngagePct: mildEngagePct,
      resumePct: resumePct,
      highPowerOverride: highPowerOverride,
      intervalSeconds: 15
    )
  }

  private func reading(
    percent: Int,
    isLowPowerModeEnabled: Bool = false,
    isOnACPower: Bool = false,
    isHighPowerMode: Bool = false
  ) -> PowerMonitor.Reading {
    PowerMonitor.Reading(
      percent: percent,
      isLowPowerModeEnabled: isLowPowerModeEnabled,
      isOnACPower: isOnACPower,
      isHighPowerMode: isHighPowerMode
    )
  }

  func testHardEngagesAtOrBelowEngageThreshold() {
    expect(
      PowerMonitor.nextState(
        reading: self.reading(percent: 20),
        config: self.config(),
        previous: .steady
      )
    ) == .init(level: .hard, hardReason: .battery)
    expect(
      PowerMonitor.nextState(
        reading: self.reading(percent: 12),
        config: self.config(),
        previous: .steady
      )
    ) == .init(level: .hard, hardReason: .battery)
  }

  func testMildEngagesInsideTheBand() {
    expect(
      PowerMonitor.nextState(
        reading: self.reading(percent: 35),
        config: self.config(),
        previous: .steady
      )
    ) == .init(level: .mild, hardReason: nil)
    expect(
      PowerMonitor.nextState(
        reading: self.reading(percent: 30),
        config: self.config(),
        previous: .steady
      )
    ) == .init(level: .mild, hardReason: nil)
    expect(
      PowerMonitor.nextState(
        reading: self.reading(percent: 21),
        config: self.config(),
        previous: .steady
      )
    ) == .init(level: .mild, hardReason: nil)
  }

  func testNoneAboveMildThreshold() {
    expect(
      PowerMonitor.nextState(
        reading: self.reading(percent: 36),
        config: self.config(),
        previous: .steady
      )
    ) == .steady
    expect(
      PowerMonitor.nextState(
        reading: self.reading(percent: 50),
        config: self.config(),
        previous: .steady
      )
    ) == .steady
  }

  func testMildDoesNotHold() {
    expect(
      PowerMonitor.nextState(
        reading: self.reading(percent: 36),
        config: self.config(),
        previous: .init(level: .mild, hardReason: nil)
      )
    ) == .steady
    expect(
      PowerMonitor.nextState(
        reading: self.reading(percent: 50),
        config: self.config(),
        previous: .init(level: .mild, hardReason: nil)
      )
    ) == .steady
  }

  func testBatteryHardHoldsThroughTheBandWhileRecharging() {
    var state = PowerMonitor.State(level: .hard, hardReason: .battery)
    for percent in stride(from: 21, through: 79, by: 1) {
      state = PowerMonitor.nextState(
        reading: self.reading(percent: percent),
        config: self.config(),
        previous: state
      )
      expect(state) == .init(level: .hard, hardReason: .battery)
    }
    state = PowerMonitor.nextState(
      reading: self.reading(percent: 80),
      config: self.config(),
      previous: state
    )
    expect(state) == .steady
  }

  func testBatteryHardHoldOverridesMild() {
    expect(
      PowerMonitor.nextState(
        reading: self.reading(percent: 30),
        config: self.config(),
        previous: .init(level: .hard, hardReason: .battery)
      )
    ) == .init(level: .hard, hardReason: .battery)
    expect(
      PowerMonitor.nextState(
        reading: self.reading(percent: 25),
        config: self.config(),
        previous: .init(level: .hard, hardReason: .battery)
      )
    ) == .init(level: .hard, hardReason: .battery)
  }

  func testDrainingEscalatesNoneToMildToHard() {
    var state = PowerMonitor.State.steady
    for percent in stride(from: 79, through: 36, by: -1) {
      state = PowerMonitor.nextState(
        reading: self.reading(percent: percent),
        config: self.config(),
        previous: state
      )
      expect(state) == .steady
    }
    for percent in stride(from: 35, through: 21, by: -1) {
      state = PowerMonitor.nextState(
        reading: self.reading(percent: percent),
        config: self.config(),
        previous: state
      )
      expect(state) == .init(level: .mild, hardReason: nil)
    }
    state = PowerMonitor.nextState(
      reading: self.reading(percent: 20),
      config: self.config(),
      previous: state
    )
    expect(state) == .init(level: .hard, hardReason: .battery)
  }

  func testLowPowerModeForcesHardAtHighBattery() {
    let state = PowerMonitor.nextState(
      reading: self.reading(percent: 90, isLowPowerModeEnabled: true),
      config: self.config(),
      previous: .steady
    )
    expect(state) == .init(level: .hard, hardReason: .lowPowerMode)
  }

  func testTurningOffLowPowerModeFallsBackToBatteryDerivedLevel() {
    let previous = PowerMonitor.State(level: .hard, hardReason: .lowPowerMode)
    let state = PowerMonitor.nextState(
      reading: self.reading(percent: 50, isLowPowerModeEnabled: false),
      config: self.config(),
      previous: previous
    )
    expect(state) == .steady
  }

  func testTurningOffLowPowerModeFallsBackToMildWhenBatteryStillLow() {
    let previous = PowerMonitor.State(level: .hard, hardReason: .lowPowerMode)
    let state = PowerMonitor.nextState(
      reading: self.reading(percent: 30, isLowPowerModeEnabled: false),
      config: self.config(),
      previous: previous
    )
    expect(state) == .init(level: .mild, hardReason: nil)
  }

  func testACHighPowerLiftsHardStopToMild() {
    let state = PowerMonitor.nextState(
      reading: self.reading(percent: 15, isOnACPower: true, isHighPowerMode: true),
      config: self.config(),
      previous: .steady
    )
    expect(state) == .init(level: .mild, hardReason: nil)
  }

  func testACHighPowerReleasesAHeldBatteryStop() {
    let state = PowerMonitor.nextState(
      reading: self.reading(percent: 15, isOnACPower: true, isHighPowerMode: true),
      config: self.config(),
      previous: .init(level: .hard, hardReason: .battery)
    )
    expect(state) == .init(level: .mild, hardReason: nil)
  }

  func testACHighPowerIsSteadyAboveMildBand() {
    let state = PowerMonitor.nextState(
      reading: self.reading(percent: 50, isOnACPower: true, isHighPowerMode: true),
      config: self.config(),
      previous: .init(level: .hard, hardReason: .battery)
    )
    expect(state) == .steady
  }

  func testHighPowerOverrideDisabledKeepsHardStop() {
    let state = PowerMonitor.nextState(
      reading: self.reading(percent: 15, isOnACPower: true, isHighPowerMode: true),
      config: self.config(highPowerOverride: false),
      previous: .steady
    )
    expect(state) == .init(level: .hard, hardReason: .battery)
  }

  func testHighPowerOnBatteryStillHardStops() {
    let state = PowerMonitor.nextState(
      reading: self.reading(percent: 15, isOnACPower: false, isHighPowerMode: true),
      config: self.config(),
      previous: .steady
    )
    expect(state) == .init(level: .hard, hardReason: .battery)
  }

  func testACWithoutHighPowerStillHardStops() {
    let state = PowerMonitor.nextState(
      reading: self.reading(percent: 15, isOnACPower: true, isHighPowerMode: false),
      config: self.config(),
      previous: .steady
    )
    expect(state) == .init(level: .hard, hardReason: .battery)
  }

  func testLowPowerModeWinsOverACHighPower() {
    let state = PowerMonitor.nextState(
      reading: self.reading(
        percent: 90,
        isLowPowerModeEnabled: true,
        isOnACPower: true,
        isHighPowerMode: true
      ),
      config: self.config(),
      previous: .steady
    )
    expect(state) == .init(level: .hard, hardReason: .lowPowerMode)
  }

  func testDisabledWhenEngageIsZero() {
    let cfg = self.config(engagePct: 0)
    expect(cfg.isDisabled) == true
  }
}
