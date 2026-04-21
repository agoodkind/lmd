//
//  FanCoordinatorTests.swift
//  SwiftLMRuntimeTests
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

// MARK: - Mock SMC driver

final class MockFanSMC: FanSMCControlling, @unchecked Sendable {
  var launchCalls: [(String, [String])] = []
  var lastAsyncRpm: [Int: Int] = [:]
  let maxByFan: [Int: Int]
  var failMaxRead: Bool

  init(maxByFan: [Int: Int] = [0: 8000, 1: 8000], failMaxRead: Bool = false) {
    self.maxByFan = maxByFan
    self.failMaxRead = failMaxRead
  }

  func runLaunchProcess(_ path: String, _ args: [String]) -> Int32 {
    launchCalls.append((path, args))
    return 0
  }

  func smcOpenIfNeededSync() throws {}

  func readFanMaxRpmSync(fanIndex: Int) throws -> Int {
    if failMaxRead {
      throw NSError(domain: "test", code: 1)
    }
    return maxByFan[fanIndex] ?? 8000
  }

  func setRpmSync(fanIndex: Int, rpm: Int) throws {}

  func setAutoSync(fanIndex: Int) throws {}

  func closeSMCConnectionSync() throws {}

  func setRpm(fanIndex: Int, rpm: Int) async throws {
    lastAsyncRpm[fanIndex] = rpm
  }

  func setAuto(fanIndex: Int) async throws {}
}

final class FanCoordinatorStateTests: XCTestCase {
  private func makeCoordinator(
    fanIndices: [Int] = [0],
    minSecondsBetweenChanges: TimeInterval = 0
  ) -> (FanCoordinator, MockFanSMC) {
    let rec = MockFanSMC()
    let cfg = FanCoordinatorConfig(
      fanIndices: fanIndices,
      minSecondsBetweenChanges: minSecondsBetweenChanges,
      activeRampDuration: 10,
      coolingRampDownSeconds: 60,
      activeFullBlastTempC: 100,
      rampMinSecondsBetweenChanges: 0
    )
    let coord = FanCoordinator(config: cfg, smc: rec)
    return (coord, rec)
  }

  func testIdleStaysIdleWithoutLLM() async throws {
    let (coord, _) = makeCoordinator()
    try await coord.apply(.init(cpuTempC: 40, gpuTempC: 42, llmLoaded: false))
    XCTAssertEqual(coord.state, .idle)
  }

  func testIdleTransitionsToActiveWhenLLMLoaded() async throws {
    let (coord, _) = makeCoordinator()
    try await coord.apply(.init(cpuTempC: 60, gpuTempC: 60, llmLoaded: true))
    XCTAssertEqual(coord.state, .active)
  }

  func testActiveToCoolingWhenLLMUnloaded() async throws {
    let (coord, _) = makeCoordinator()
    try await coord.apply(.init(cpuTempC: 80, gpuTempC: 85,
                               cpuPercent: 30, gpuPercent: 90,
                               pressureFreePct: 50, llmLoaded: true))
    XCTAssertEqual(coord.state, .active)
    try await coord.apply(.init(cpuTempC: 80, gpuTempC: 85,
                                cpuPercent: 5, gpuPercent: 0,
                                pressureFreePct: 50, llmLoaded: false))
    XCTAssertEqual(coord.state, .cooling)
  }

  func testActiveRampInterpolatesTowardSMCMax() async throws {
    let mock = MockFanSMC(maxByFan: [0: 8000])
    let cfg = FanCoordinatorConfig(
      fanIndices: [0],
      minSecondsBetweenChanges: 0,
      activeRampDuration: 10,
      activeFullBlastTempC: 100,
      rampMinSecondsBetweenChanges: 0
    )
    let coord = FanCoordinator(config: cfg, smc: mock)
    coord.takeOver()
    let t0 = Date()
    try await coord.apply(
      FanInputs(cpuTempC: 50, gpuTempC: 50, llmLoaded: true),
      now: t0
    )
    let tMid = t0.addingTimeInterval(5)
    try await coord.apply(
      FanInputs(cpuTempC: 50, gpuTempC: 50, llmLoaded: true),
      now: tMid
    )
    XCTAssertEqual(mock.lastAsyncRpm[0], 6000)
  }

  func testActiveFullBlastAtSmoothedTemp() async throws {
    let mock = MockFanSMC(maxByFan: [0: 8000])
    let cfg = FanCoordinatorConfig(
      fanIndices: [0],
      minSecondsBetweenChanges: 0,
      loadEmaAlpha: 1.0,
      tempEmaAlpha: 1.0,
      activeRampDuration: 0.001,
      activeFullBlastTempC: 50,
      rampMinSecondsBetweenChanges: 0
    )
    let coord = FanCoordinator(config: cfg, smc: mock)
    try await coord.apply(
      FanInputs(cpuTempC: 95, gpuTempC: 95, llmLoaded: true),
      now: Date()
    )
    XCTAssertEqual(mock.lastAsyncRpm[0], 10_000)
  }

  func testFallbackMaxWhenTakeOverCannotReadMax() async throws {
    let mock = MockFanSMC(failMaxRead: true)
    let cfg = FanCoordinatorConfig(fanIndices: [0], fallbackMaxRpm: 7777)
    let coord = FanCoordinator(config: cfg, smc: mock)
    coord.takeOver()
    let base = Date()
    try await coord.apply(
      FanInputs(cpuTempC: 50, gpuTempC: 50, llmLoaded: true),
      now: base
    )
    try await coord.apply(
      FanInputs(cpuTempC: 50, gpuTempC: 50, llmLoaded: true),
      now: base.addingTimeInterval(20)
    )
    XCTAssertEqual(mock.lastAsyncRpm[0], 7777)
  }
}
