//
//  SensorParseTests.swift
//  SwiftLMMonitorTests
//
//  Created by Alex Goodkind <alex@goodkind.io> on 2026-04-18.
//  Copyright © 2026
//

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
    XCTAssertEqual(snap.pagesFree, 1234)
    XCTAssertEqual(snap.pagesActive, 5678)
    XCTAssertEqual(snap.pagesInactive, 9012)
    XCTAssertEqual(snap.pagesWired, 345)
    XCTAssertEqual(snap.pagesCompressed, 67890)
    XCTAssertEqual(snap.pageins, 11111)
    XCTAssertEqual(snap.pageouts, 22)
    XCTAssertEqual(snap.compressions, 333_333)
    XCTAssertEqual(snap.decompressions, 444_444)
  }
}

final class SwapUsageParseTests: XCTestCase {
  func testParsesUsedAndTotal() {
    let sample = "total = 2048.00M  used = 62148.06M  free = 0.00M  (encrypted)"
    let snap = SwapUsage.parse(sample)
    XCTAssertEqual(snap.total, "2048.00M")
    XCTAssertEqual(snap.used, "62148.06M")
  }
}

final class LoadAverageParseTests: XCTestCase {
  func testExtractsOneMinute() {
    let sample = "{ 1.20 2.30 3.40 }"
    XCTAssertEqual(LoadAverage.parseOneMinute(sample), 1.20, accuracy: 0.01)
  }
}

final class MemoryPressureParseTests: XCTestCase {
  func testExtractsPercentage() {
    let sample = """
The system has 137438953472 (33554432 pages) of RAM
System-wide memory free percentage: 64%
"""
    XCTAssertEqual(MemoryPressure.parseFreePercent(sample), 64)
  }
}

final class BatteryParseTests: XCTestCase {
  func testChargingOnAC() {
    let sample = """
Now drawing from 'AC Power'
 -InternalBattery-0 (id=12345) 82%; charging; not in use
"""
    let snap = Battery.parse(sample)
    XCTAssertEqual(snap.percent, 82)
    XCTAssertEqual(snap.acState, "charging")
    XCTAssertEqual(snap.source, "AC Power")
  }

  func testDischargingOnBattery() {
    let sample = """
Now drawing from 'Battery'
 -InternalBattery-0 (id=12345) 45%; discharging; not in use
"""
    let snap = Battery.parse(sample)
    XCTAssertEqual(snap.percent, 45)
    XCTAssertEqual(snap.acState, "battery")
    XCTAssertEqual(snap.source, "Battery")
  }

  func testEmptyInputYieldsZero() {
    let snap = Battery.parse("")
    XCTAssertEqual(snap.percent, 0)
    XCTAssertEqual(snap.acState, "unknown")
  }
}
