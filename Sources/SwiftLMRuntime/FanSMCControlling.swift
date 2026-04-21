//
//  FanSMCControlling.swift
//  SwiftLMRuntime
//

import Foundation

/// Privileged SMC fan I/O used by ``FanCoordinator``. Production uses
/// ``LiveFanSMCController`` (XPC to `smcd` arbiter). Tests inject a mock.
public protocol FanSMCControlling: Sendable {
  func runLaunchProcess(_ path: String, _ args: [String]) -> Int32

  /// Opens the helper SMC session if not already open.
  func smcOpenIfNeededSync() throws

  func readFanMaxRpmSync(fanIndex: Int) throws -> Int

  func setRpmSync(fanIndex: Int, rpm: Int) throws

  func setAutoSync(fanIndex: Int) throws

  func closeSMCConnectionSync() throws

  func setRpm(fanIndex: Int, rpm: Int) async throws

  func setAuto(fanIndex: Int) async throws

  /// Updates the priority used for every subsequent write. Called by
  /// `FanCoordinator` on state transitions so lower priority clients
  /// (fancurveagent) can regain fans once lmd enters cooling.
  func setCurrentPriority(_ priority: Int)
}
