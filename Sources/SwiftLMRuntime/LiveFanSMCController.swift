//
//  LiveFanSMCController.swift
//  SwiftLMRuntime
//

import AppLogger
import Foundation
import SMCFanXPCClient

/// Routes fan control through the privileged XPC helper from macos-smc-fan.
public final class LiveFanSMCController: FanSMCControlling, @unchecked Sendable {
  private let log = AppLogger.logger(category: "LiveFanSMCController")
  private let xpc: SMCFanXPCClient
  private var smcOpened = false

  public init() throws {
    log.notice("smc_controller_init")
    self.xpc = try SMCFanXPCClient()
  }

  public func runLaunchProcess(_ path: String, _ args: [String]) -> Int32 {
    FanCoordinator.runLaunchProcess(path, args)
  }

  public func smcOpenIfNeededSync() throws {
    guard !self.smcOpened else { return }
    log.debug("smc.open_sync_before openState=\(self.smcOpened, privacy: .public)")
    try xpc.openSync()
    log.debug("smc.open_sync_after")
    self.smcOpened = true
  }

  public func readFanMaxRpmSync(fanIndex: Int) throws -> Int {
    log.debug("smc.read_fan_max fan=\(fanIndex, privacy: .public)")
    let info = try xpc.getFanInfoSync(UInt(fanIndex))
    log.debug("smc.read_fan_max_completed fan=\(fanIndex, privacy: .public) max_rpm=\(Int(info.maxRPM.rounded()), privacy: .public)")
    return Int(info.maxRPM.rounded())
  }

  public func setRpmSync(fanIndex: Int, rpm: Int) throws {
    log.debug("smc.set_rpm_sync fan=\(fanIndex, privacy: .public) rpm=\(rpm, privacy: .public)")
    try xpc.setFanRPMSync(UInt(fanIndex), rpm: Float(rpm))
  }

  public func setAutoSync(fanIndex: Int) throws {
    log.debug("smc.set_auto_sync fan=\(fanIndex, privacy: .public)")
    try xpc.setFanAutoSync(UInt(fanIndex))
  }

  public func closeSMCConnectionSync() throws {
    guard self.smcOpened else { return }
    log.debug("smc.close_connection")
    try xpc.closeSync()
    self.smcOpened = false
  }

  public func setRpm(fanIndex: Int, rpm: Int) async throws {
    log.debug("smc.set_rpm fan=\(fanIndex, privacy: .public) rpm=\(rpm, privacy: .public)")
    try await xpc.setFanRPM(UInt(fanIndex), rpm: Float(rpm))
  }

  public func setAuto(fanIndex: Int) async throws {
    log.debug("smc.set_auto fan=\(fanIndex, privacy: .public)")
    try await xpc.setFanAuto(UInt(fanIndex))
  }
}
