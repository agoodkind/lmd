//
//  MonitorTabTests.swift
//  SwiftLMTUITests
//
//  Created by Alex Goodkind <alex@goodkind.io> on 2026-04-18.
//  Copyright © 2026
//

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
    XCTAssertTrue(combined.contains("discharging"), "expected discharging label, got:\n\(combined)")
    XCTAssertTrue(combined.contains("-15.0 W"))
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
    XCTAssertTrue(combined.contains("+25.0 W"))
    XCTAssertTrue(combined.contains("charging"))
  }

  func testQuitActionOnQKey() {
    let tab = MonitorTab()
    let action = tab.handle(.key(.quit))
    if case .quit = action {} else { XCTFail("expected .quit, got \(action)") }
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
    XCTAssertEqual(snap.cpuTempC, 55)
    XCTAssertEqual(snap.gpuTempC, 60)
    XCTAssertEqual(snap.battPct, 77)
    XCTAssertEqual(snap.battWattsSigned, -5.5)
    XCTAssertEqual(snap.acState, "charging")
  }
}
