//
//  SensorParseTests.swift
//  SwiftLMMonitorTests
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-04-18.
//  Copyright © 2026, all rights reserved.
//

import Nimble
import XCTest

@testable import SwiftLMMonitor

final class VMStatParseTests: XCTestCase {
  func testExtractsFields() {
    let sample = """
      Mach Virtual Memory Statistics:
      Pages free:                               1234.
      Pages active:                          5678.
      Pages inactive:                         9012.
      Pages wired down:                        345.
      Pages stored in compressor:           67890.
      Pageins:                              11111.
      Pageouts:                                22.
      Compressions:                        333333.
      Decompressions:                      444444.
      """
    let snap = VMStat.parse(sample)
    expect(snap.pagesFree) == 1_234
    expect(snap.pagesActive) == 5_678
    expect(snap.pagesInactive) == 9_012
    expect(snap.pagesWired) == 345
    expect(snap.pagesCompressed) == 67_890
    expect(snap.pageins) == 11_111
    expect(snap.pageouts) == 22
    expect(snap.compressions) == 333_333
    expect(snap.decompressions) == 444_444
  }
}

final class SwapUsageParseTests: XCTestCase {
  func testParsesUsedAndTotal() {
    let sample = "total = 2048.00M  used = 62148.06M  free = 0.00M  (encrypted)"
    let snap = SwapUsage.parse(sample)
    expect(snap.total) == "2048.00M"
    expect(snap.used) == "62148.06M"
  }
}

final class LoadAverageParseTests: XCTestCase {
  func testExtractsOneMinute() {
    let sample = "{ 1.20 2.30 3.40 }"
    expect(LoadAverage.parseOneMinute(sample)) == (expected: 1.20, delta: 0.01)
  }
}

final class MemoryPressureParseTests: XCTestCase {
  func testExtractsPercentage() {
    let sample = """
      The system has 137438953472 (33554432 pages) of RAM
      System-wide memory free percentage: 64%
      """
    expect(MemoryPressure.parseFreePercent(sample)) == 64
  }
}

final class BatteryParseTests: XCTestCase {
  func testChargingOnAC() {
    let sample = """
      Now drawing from 'AC Power'
       -InternalBattery-0 (id=12345) 82%; charging; not in use
      """
    let snap = Battery.parse(sample)
    expect(snap.percent) == 82
    expect(snap.acState) == "charging"
    expect(snap.source) == "AC Power"
  }

  func testDischargingOnBattery() {
    let sample = """
      Now drawing from 'Battery'
       -InternalBattery-0 (id=12345) 45%; discharging; not in use
      """
    let snap = Battery.parse(sample)
    expect(snap.percent) == 45
    expect(snap.acState) == "battery"
    expect(snap.source) == "Battery"
  }

  func testEmptyInputYieldsZero() {
    let snap = Battery.parse("")
    expect(snap.percent) == 0
    expect(snap.acState) == "unknown"
  }

  func testHighPowerModeDetectedFromPmset() {
    let sample = """
      Currently in use:
       hibernatemode        3
       powermode            2
       womp                 1
      """
    expect(Battery.parseHighPowerMode(sample)) == true
  }

  func testAutomaticModeIsNotHighPower() {
    let sample = """
      Currently in use:
       powermode            0
       womp                 1
      """
    expect(Battery.parseHighPowerMode(sample)) == false
  }

  func testMissingPowerModeLineIsNotHighPower() {
    let sample = """
      Currently in use:
       hibernatemode        3
       womp                 1
      """
    expect(Battery.parseHighPowerMode(sample)) == false
  }
}
