//
//  FanCoordinatorTests.swift
//  SwiftLMRuntimeTests
//
//  Created by Alex Goodkind <alex@goodkind.io> on 2026-04-18.
//  Copyright © 2026
//

import XCTest
@testable import SwiftLMRuntime

final class FanCurveTests: XCTestCase {
  func testTempBelowCurveReturnsFloor() {
    let rpm = rpmForTemp(40, curve: FanCoordinatorConfig.defaultCurve)
    XCTAssertEqual(rpm, 2500)
  }

  func testTempAboveCurveReturnsCeiling() {
    let rpm = rpmForTemp(99, curve: FanCoordinatorConfig.defaultCurve)
    XCTAssertEqual(rpm, 10_000)
  }

  func testMidCurveInterpolates() {
    // Between 50C (2500) and 65C (3500), at 57.5C expect ~3000.
    let rpm = rpmForTemp(57.5, curve: FanCoordinatorConfig.defaultCurve)
    XCTAssertEqual(rpm, 3000, accuracy: 50)
  }
}

final class ActivityFloorTests: XCTestCase {
  func testGPULoadRaisesFloor() {
    let floor = activityFloorRpm(
      cpuPercent: 0, gpuPercent: 85,
      pressureFreePct: 100, llmActive: false
    )
    XCTAssertGreaterThanOrEqual(floor, 4500)
  }

  func testPressureLowRaisesFloor() {
    let floor = activityFloorRpm(
      cpuPercent: 0, gpuPercent: 0,
      pressureFreePct: 5, llmActive: false
    )
    XCTAssertGreaterThanOrEqual(floor, 4500)
  }

  func testLLMActiveRaisesFloorEvenAtLowGPU() {
    let baseline = activityFloorRpm(
      cpuPercent: 0, gpuPercent: 0,
      pressureFreePct: 100, llmActive: false
    )
    let withLLM = activityFloorRpm(
      cpuPercent: 0, gpuPercent: 0,
      pressureFreePct: 100, llmActive: true
    )
    XCTAssertGreaterThan(withLLM, baseline)
  }

  func testIdleReturnsZero() {
    let floor = activityFloorRpm(
      cpuPercent: 0, gpuPercent: 0,
      pressureFreePct: 100, llmActive: false
    )
    XCTAssertEqual(floor, 0)
  }
}

final class FanCoordinatorStateTests: XCTestCase {
  /// Drop-in shell stub that records every call for verification.
  final class RecordingShell {
    var calls: [(String, [String])] = []
    func run(_ path: String, _ args: [String]) -> Int32 {
      calls.append((path, args))
      return 0
    }
  }

  private func makeCoordinator() -> (FanCoordinator, RecordingShell) {
    let rec = RecordingShell()
    let cfg = FanCoordinatorConfig(
      smcfanBinary: "/usr/local/bin/smcfan",
      minSecondsBetweenChanges: 0  // unlimit so tests can poke state in sequence
    )
    let coord = FanCoordinator(config: cfg) { path, args in rec.run(path, args) }
    return (coord, rec)
  }

  func testIdleStaysIdleWithoutLLM() {
    let (coord, _) = makeCoordinator()
    coord.apply(.init(cpuTempC: 40, gpuTempC: 42, llmLoaded: false))
    XCTAssertEqual(coord.state, .idle)
  }

  func testIdleTransitionsToActiveWhenLLMLoads() {
    let (coord, _) = makeCoordinator()
    // Need to saturate the smoothed gpu% above 20 first; with alpha 0.20
    // a single sample at 100% lands at 20 so it triggers.
    coord.apply(.init(cpuTempC: 60, gpuTempC: 60,
                       cpuPercent: 50, gpuPercent: 100,
                       pressureFreePct: 50, llmLoaded: true))
    XCTAssertEqual(coord.state, .active)
  }

  func testActiveToCoolingWhenGPUQuiets() {
    let (coord, _) = makeCoordinator()
    for _ in 0..<3 {
      coord.apply(.init(cpuTempC: 80, gpuTempC: 85,
                         cpuPercent: 30, gpuPercent: 90,
                         pressureFreePct: 50, llmLoaded: true))
    }
    XCTAssertEqual(coord.state, .active)
    coord.apply(.init(cpuTempC: 80, gpuTempC: 85,
                       cpuPercent: 5, gpuPercent: 0,
                       pressureFreePct: 50, llmLoaded: false))
    XCTAssertEqual(coord.state, .cooling)
  }
}
