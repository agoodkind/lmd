//
//  MonitorTabTests.swift
//  SwiftLMTUITests
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-04-18.
//  Copyright © 2026, all rights reserved.
//

import Nimble
import XCTest

@testable import SwiftLMTUI

final class MonitorTabTests: XCTestCase {
  func testRendersDischargeInRed() {
    let tab = MonitorTab()
    tab.snapshot = MonitorSnapshot(
      cpuTempC: 60, gpuTempC: 70,
      cpuPercent: 10, gpuPercent: 80,
      systemPowerW: 100, ramUsedGB: 100,
      pressureFreePct: 50,
      battPct: 55, battWattsSigned: -15.0, acState: "charging"
    )
    let buf = BufferedScreen(rows: 30, cols: 80)
    tab.render(into: buf, contentRows: 1...25)
    // The "flow" row should mention discharging somewhere.
    let combined = buf.rowsPainted.values.joined(separator: "\n")
    expect(combined.contains("discharging")) == true
    expect(combined.contains("-15.0 W")) == true
  }

  func testRendersChargingInGreen() {
    let tab = MonitorTab()
    tab.snapshot = MonitorSnapshot(
      cpuTempC: 40, gpuTempC: 40,
      cpuPercent: 5, gpuPercent: 5,
      systemPowerW: 30, ramUsedGB: 40,
      pressureFreePct: 80,
      battPct: 70, battWattsSigned: 25.0, acState: "charging"
    )
    let buf = BufferedScreen(rows: 30, cols: 80)
    tab.render(into: buf, contentRows: 1...25)
    let combined = buf.rowsPainted.values.joined(separator: "\n")
    expect(combined.contains("+25.0 W")) == true
    expect(combined.contains("charging")) == true
  }

  func testQuitActionOnQKey() {
    let tab = MonitorTab()
    let action = tab.handle(.key(.quit))
    if case .quit = action {} else { fail("expected .quit, got \(action)") }
  }

  func testSnapshotParsesFromJSON() {
    let json: [String: Any] = [
      "cpu_temp_c": 55.0,
      "gpu_temp_c": 60.0,
      "cpu_pct": 12.0,
      "gpu_pct": 85.0,
      "sys_power_w": 100.0,
      "ram_used_gb": 42.0,
      "pressure_free_pct": 65,
      "batt_pct": 77,
      "batt_watts_signed": -5.5,
      "ac_state": "charging",
    ]
    let snap = MonitorSnapshot.from(json: json)
    expect(snap.cpuTempC) == 55
    expect(snap.gpuTempC) == 60
    expect(snap.battPct) == 77
    expect(snap.battWattsSigned) == -5.5
    expect(snap.acState) == "charging"
  }
}
