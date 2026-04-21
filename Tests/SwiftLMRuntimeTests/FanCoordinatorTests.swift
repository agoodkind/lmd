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

  var lastPriority: Int = 0
  func setCurrentPriority(_ priority: Int) { lastPriority = priority }
}

final class FanCoordinatorStateTests: XCTestCase {
  private func makeCoordinator(
    fanIndices: [Int] = [0],
    minSecondsBetweenChanges: TimeInterval = 0,
    holdSeconds: TimeInterval = 90,
    coolingRampDownSeconds: TimeInterval = 180,
    loadEmaAlpha: Double = 1.0,
    tempEmaAlpha: Double = 1.0
  ) -> (FanCoordinator, MockFanSMC) {
    let rec = MockFanSMC()
    let cfg = FanCoordinatorConfig(
      fanIndices: fanIndices,
      minSecondsBetweenChanges: minSecondsBetweenChanges,
      loadEmaAlpha: loadEmaAlpha,
      tempEmaAlpha: tempEmaAlpha,
      activeRampDuration: 10,
      holdSeconds: holdSeconds,
      coolingRampDownSeconds: coolingRampDownSeconds,
      activeFullBlastTempC: 100,
      rampMinSecondsBetweenChanges: 0
    )
    let coord = FanCoordinator(config: cfg, smc: rec)
    coord.takeOver()
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

  /// Active ramp interpolates from takeover baseline toward the temperature-
  /// responsive active steady target, not toward SMC max.
  func testActiveRampInterpolatesTowardActiveSteady() async throws {
    let mock = MockFanSMC(maxByFan: [0: 8000])
    let cfg = FanCoordinatorConfig(
      fanIndices: [0],
      minSecondsBetweenChanges: 0,
      loadEmaAlpha: 1.0,
      tempEmaAlpha: 1.0,
      activeRampDuration: 10,
      activeFullBlastTempC: 100,
      rampMinSecondsBetweenChanges: 0
    )
    let coord = FanCoordinator(config: cfg, smc: mock)
    coord.takeOver()
    let t0 = Date()
    // gpu=90% with llm-active raises floor to 5800.
    // curve(50°C) = 2500, so steady target = max(2500, 5800) = 5800.
    // Baseline from takeOver is startupBaselineRpm = 4000.
    try await coord.apply(
      FanInputs(cpuTempC: 50, gpuTempC: 50, gpuPercent: 90, llmLoaded: true),
      now: t0
    )
    try await coord.apply(
      FanInputs(cpuTempC: 50, gpuTempC: 50, gpuPercent: 90, llmLoaded: true),
      now: t0.addingTimeInterval(5)
    )
    // At 50% ramp: (4000 + 5800) / 2 = 4900.
    XCTAssertEqual(mock.lastAsyncRpm[0] ?? 0, 4900, accuracy: 50)
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

  /// 75°C (the new default full-blast threshold) should trip full-blast during
  /// the active state.
  func testActiveFullBlastAt75DefaultThreshold() async throws {
    let mock = MockFanSMC(maxByFan: [0: 8000])
    let cfg = FanCoordinatorConfig(
      fanIndices: [0],
      minSecondsBetweenChanges: 0,
      loadEmaAlpha: 1.0,
      tempEmaAlpha: 1.0,
      activeRampDuration: 0.001,
      rampMinSecondsBetweenChanges: 0
    )
    let coord = FanCoordinator(config: cfg, smc: mock)
    try await coord.apply(
      FanInputs(cpuTempC: 75, gpuTempC: 75, llmLoaded: true),
      now: Date()
    )
    XCTAssertEqual(mock.lastAsyncRpm[0], 10_000)
  }

  /// Failing SMC max read must not prevent the coordinator from writing a
  /// sensible RPM. Previously it was used as the active ceiling; now it's
  /// only recorded for reference, and the active target comes from curve+floor.
  func testCoordinatorSurvivesMaxReadFailure() async throws {
    let mock = MockFanSMC(failMaxRead: true)
    let cfg = FanCoordinatorConfig(
      fanIndices: [0],
      minSecondsBetweenChanges: 0,
      loadEmaAlpha: 1.0,
      tempEmaAlpha: 1.0,
      activeRampDuration: 0.001,
      activeFullBlastTempC: 100,
      rampMinSecondsBetweenChanges: 0,
      fallbackMaxRpm: 7777
    )
    let coord = FanCoordinator(config: cfg, smc: mock)
    coord.takeOver()
    let base = Date()
    try await coord.apply(
      FanInputs(cpuTempC: 50, gpuTempC: 50, gpuPercent: 90, llmLoaded: true),
      now: base
    )
    try await coord.apply(
      FanInputs(cpuTempC: 50, gpuTempC: 50, gpuPercent: 90, llmLoaded: true),
      now: base.addingTimeInterval(20)
    )
    // gpu=90% with llm active → floor 5800; curve(50°C) = 2500; steady = 5800.
    XCTAssertEqual(mock.lastAsyncRpm[0] ?? 0, 5800, accuracy: 50)
  }

  /// After LLM unloads, fans hold their active RPM for holdSeconds before
  /// the ramp begins.
  func testHoldPhaseHoldsRpmAfterUnload() async throws {
    let mock = MockFanSMC(maxByFan: [0: 8000])
    let cfg = FanCoordinatorConfig(
      fanIndices: [0],
      minSecondsBetweenChanges: 0,
      loadEmaAlpha: 1.0,
      tempEmaAlpha: 1.0,
      activeRampDuration: 0.01,
      holdSeconds: 90,
      coolingRampDownSeconds: 180,
      activeFullBlastTempC: 100,
      rampMinSecondsBetweenChanges: 0
    )
    let coord = FanCoordinator(config: cfg, smc: mock)
    coord.takeOver()
    let t0 = Date()
    // Enter active and let ramp complete so the steady active target is
    // actually written (gpu=90%, llm-on → floor 5800).
    try await coord.apply(
      FanInputs(cpuTempC: 55, gpuTempC: 55, gpuPercent: 90, llmLoaded: true),
      now: t0
    )
    try await coord.apply(
      FanInputs(cpuTempC: 55, gpuTempC: 55, gpuPercent: 90, llmLoaded: true),
      now: t0.addingTimeInterval(1)
    )
    let activeRpm = mock.lastAsyncRpm[0] ?? 0
    XCTAssertGreaterThan(activeRpm, 4000)

    // Unload LLM: enters .cooling, starts hold phase.
    try await coord.apply(
      FanInputs(cpuTempC: 55, gpuTempC: 55, gpuPercent: 0, llmLoaded: false),
      now: t0.addingTimeInterval(2)
    )
    XCTAssertEqual(coord.state, .cooling)

    // Mid-hold (45s into 90s hold): still holding activeRpm.
    try await coord.apply(
      FanInputs(cpuTempC: 55, gpuTempC: 55, gpuPercent: 0, llmLoaded: false),
      now: t0.addingTimeInterval(45)
    )
    XCTAssertEqual(mock.lastAsyncRpm[0] ?? 0, activeRpm)
  }

  /// After the hold window elapses, fans ramp down toward the cooling steady
  /// target over coolingRampDownSeconds.
  func testCoolingRampStartsAfterHoldWindow() async throws {
    let mock = MockFanSMC(maxByFan: [0: 8000])
    let cfg = FanCoordinatorConfig(
      fanIndices: [0],
      rampUpMinDelta: 0,
      rampDownMinDelta: 0,
      minSecondsBetweenChanges: 0,
      coolOffTempC: 30,
      loadEmaAlpha: 1.0,
      tempEmaAlpha: 1.0,
      activeRampDuration: 0.01,
      holdSeconds: 10,
      coolingRampDownSeconds: 20,
      activeFullBlastTempC: 100,
      rampMinSecondsBetweenChanges: 0
    )
    let coord = FanCoordinator(config: cfg, smc: mock)
    coord.takeOver()
    let t0 = Date()
    try await coord.apply(
      FanInputs(cpuTempC: 55, gpuTempC: 55, gpuPercent: 90, llmLoaded: true),
      now: t0
    )
    try await coord.apply(
      FanInputs(cpuTempC: 55, gpuTempC: 55, gpuPercent: 90, llmLoaded: true),
      now: t0.addingTimeInterval(1)
    )
    let activeRpm = mock.lastAsyncRpm[0] ?? 0
    XCTAssertGreaterThan(activeRpm, 4000)

    try await coord.apply(
      FanInputs(cpuTempC: 55, gpuTempC: 55, gpuPercent: 0, llmLoaded: false),
      now: t0.addingTimeInterval(2)
    )

    // Cooling entered at t0+2. Hold ends at t0+12, ramp ends at t0+32.
    // Sample mid-ramp at t0+22 (10s into 20s ramp = 50%).
    try await coord.apply(
      FanInputs(cpuTempC: 55, gpuTempC: 55, gpuPercent: 0, llmLoaded: false),
      now: t0.addingTimeInterval(22)
    )
    let midRampRpm = mock.lastAsyncRpm[0] ?? 0
    XCTAssertLessThan(midRampRpm, activeRpm)

    // Past ramp end (t0+40): at steady cooling target.
    try await coord.apply(
      FanInputs(cpuTempC: 55, gpuTempC: 55, gpuPercent: 0, llmLoaded: false),
      now: t0.addingTimeInterval(40)
    )
    let finalRpm = mock.lastAsyncRpm[0] ?? 0
    XCTAssertLessThan(finalRpm, midRampRpm)
  }

  /// A failed baseline set during takeover is logged but does not drop the fan
  /// from the active set. The helper often applies the SMC write but fails to
  /// reply; the tick loop reasserts the target anyway, so the coordinator
  /// keeps both fans under control.
  func testTakeoverSurvivesBaselineWriteFailure() async throws {
    final class OneFanFailingSMC: FanSMCControlling, @unchecked Sendable {
      var lastAsyncRpm: [Int: Int] = [:]
      func runLaunchProcess(_ path: String, _ args: [String]) -> Int32 { 0 }
      func smcOpenIfNeededSync() throws {}
      func readFanMaxRpmSync(fanIndex: Int) throws -> Int { 8000 }
      func setRpmSync(fanIndex: Int, rpm: Int) throws {
        if fanIndex == 1 { throw NSError(domain: "test", code: 1) }
      }
      func setAutoSync(fanIndex: Int) throws {}
      func closeSMCConnectionSync() throws {}
      func setRpm(fanIndex: Int, rpm: Int) async throws {
        lastAsyncRpm[fanIndex] = rpm
      }
      func setAuto(fanIndex: Int) async throws {}
      func setCurrentPriority(_ priority: Int) {}
    }
    let mock = OneFanFailingSMC()
    let cfg = FanCoordinatorConfig(
      fanIndices: [0, 1],
      minSecondsBetweenChanges: 0,
      loadEmaAlpha: 1.0,
      tempEmaAlpha: 1.0,
      activeRampDuration: 0.001,
      activeFullBlastTempC: 100,
      rampMinSecondsBetweenChanges: 0
    )
    let coord = FanCoordinator(config: cfg, smc: mock)
    coord.takeOver()
    let t0 = Date()
    try await coord.apply(
      FanInputs(cpuTempC: 55, gpuTempC: 55, gpuPercent: 90, llmLoaded: true),
      now: t0
    )
    try await coord.apply(
      FanInputs(cpuTempC: 55, gpuTempC: 55, gpuPercent: 90, llmLoaded: true),
      now: t0.addingTimeInterval(1)
    )
    // Both fans stay in the active set; the tick loop writes to both.
    XCTAssertGreaterThan(mock.lastAsyncRpm[0] ?? 0, 0)
    XCTAssertGreaterThan(mock.lastAsyncRpm[1] ?? 0, 0)
    XCTAssertEqual(coord.state, .active)
  }
}
