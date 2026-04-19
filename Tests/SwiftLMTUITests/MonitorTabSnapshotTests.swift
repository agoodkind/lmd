//
//  MonitorTabSnapshotTests.swift
//  SwiftLMTUITests
//
//  Created by Alex Goodkind <alex@goodkind.io> on 2026-04-18.
//  Copyright © 2026
//
//  Golden-file snapshot tests for `MonitorTab`. Each scenario constructs
//  a deterministic `MonitorSnapshot`, renders into a `BufferedScreen`,
//  and diffs the ANSI-stripped grid against a checked-in golden.
//
//  Regenerate after a deliberate render change:
//      SNAPSHOT_UPDATE=1 swift test --filter MonitorTabSnapshot
//  or `make snapshot-update`.
//

import XCTest
@testable import SwiftLMTUI

final class MonitorTabSnapshotTests: XCTestCase {
  func testIdleOnBattery() throws {
    let tab = MonitorTab()
    tab.snapshot = MonitorSnapshot(
      cpuTempC: 32.5, gpuTempC: 30.0,
      cpuPercent: 2.0, gpuPercent: 0.0,
      systemPowerW: 6.4,
      ramUsedGB: 24.0,
      pressureFreePct: 80,
      battPct: 92, battWattsSigned: -5.2, acState: "battery"
    )
    let buffer = BufferedScreen(rows: 30, cols: 120)
    tab.render(into: buffer, contentRows: 3...28)
    try Snapshot.assertMatches(Snapshot.compose(buffer), name: "monitor_idle_on_battery")
  }

  func testUnderHeavyLoadCharging() throws {
    let tab = MonitorTab()
    tab.snapshot = MonitorSnapshot(
      cpuTempC: 82.3, gpuTempC: 88.7,
      cpuPercent: 94.0, gpuPercent: 99.0,
      systemPowerW: 140.1,
      ramUsedGB: 96.7,
      pressureFreePct: 18,
      battPct: 55, battWattsSigned: 18.4, acState: "charging"
    )
    let buffer = BufferedScreen(rows: 30, cols: 120)
    tab.render(into: buffer, contentRows: 3...28)
    try Snapshot.assertMatches(Snapshot.compose(buffer), name: "monitor_under_load_charging")
  }

  func testBatteryCritical() throws {
    let tab = MonitorTab()
    tab.snapshot = MonitorSnapshot(
      cpuTempC: 45.0, gpuTempC: 42.0,
      cpuPercent: 15.0, gpuPercent: 5.0,
      systemPowerW: 12.3,
      ramUsedGB: 40.0,
      pressureFreePct: 55,
      battPct: 8, battWattsSigned: -12.7, acState: "battery"
    )
    let buffer = BufferedScreen(rows: 30, cols: 120)
    tab.render(into: buffer, contentRows: 3...28)
    try Snapshot.assertMatches(Snapshot.compose(buffer), name: "monitor_battery_critical")
  }

  func testEmpty() throws {
    let tab = MonitorTab()
    // MonitorSnapshot.empty: all zeros, ac_state == "unknown".
    let buffer = BufferedScreen(rows: 30, cols: 120)
    tab.render(into: buffer, contentRows: 3...28)
    try Snapshot.assertMatches(Snapshot.compose(buffer), name: "monitor_empty")
  }
}
