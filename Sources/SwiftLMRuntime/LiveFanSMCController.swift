//
//  LiveFanSMCController.swift
//  SwiftLMRuntime
//
//  Created by Alex Goodkind <alex@goodkind.io> on 2026-04-20.
//  Copyright © 2026
//

import AppLogger
import Foundation
import SMCFanProtocol
import SMCFanXPCClient

/// Routes fan control through the privileged `smcfanhelper` via
/// `SMCFanXPCClient`. The helper arbitrates priority internally, so this
/// controller just threads the current priority through each write.
/// Preemption is expected (fancurveagent or the CLI may hold a fan at a
/// higher priority) and surfaces as `SMCXPCConflictError`; we log at
/// debug and let the coordinator's next tick retry.
public final class LiveFanSMCController: FanSMCControlling, @unchecked Sendable {
  private let log = AppLogger.logger(category: "LiveFanSMCController")
  private let client: SMCFanXPCClient
  private let priorityLock = NSLock()
  private var currentPriority: Int

  /// `throws` is retained for source compatibility with `try?` at call sites.
  public init(
    clientName: String = "lmd-serve",
    defaultPriority: Int = SMCFanPriority.llmActive
  ) throws {
    self.client = try SMCFanXPCClient(
      clientName: clientName,
      defaultPriority: defaultPriority
    )
    self.currentPriority = defaultPriority
    log.notice(
      "smc.controller_init client_name=\(clientName, privacy: .public) priority=\(defaultPriority, privacy: .public)"
    )
  }

  public func setCurrentPriority(_ priority: Int) {
    self.priorityLock.lock()
    let changed = self.currentPriority != priority
    self.currentPriority = priority
    self.priorityLock.unlock()
    if changed {
      log.info(
        "smc.priority_changed priority=\(priority, privacy: .public)"
      )
    }
  }

  private func priority() -> Int {
    self.priorityLock.lock()
    let v = self.currentPriority
    self.priorityLock.unlock()
    return v
  }

  public func runLaunchProcess(_ path: String, _ args: [String]) -> Int32 {
    FanCoordinator.runLaunchProcess(path, args)
  }

  // MARK: - Synchronous API (takeover / release / atexit)

  public func smcOpenIfNeededSync() throws {
    try client.openSync()
  }

  public func readFanMaxRpmSync(fanIndex: Int) throws -> Int {
    log.debug("smc.read_fan_max fan=\(fanIndex, privacy: .public)")
    let info = try client.getFanInfoSync(UInt(fanIndex))
    let maxRpm = Int(info.maxRPM.rounded())
    log.debug(
      "smc.read_fan_max_completed fan=\(fanIndex, privacy: .public) max_rpm=\(maxRpm, privacy: .public)"
    )
    return maxRpm
  }

  public func setRpmSync(fanIndex: Int, rpm: Int) throws {
    let pri = self.priority()
    log.debug(
      "smc.set_rpm_sync fan=\(fanIndex, privacy: .public) rpm=\(rpm, privacy: .public) priority=\(pri, privacy: .public)"
    )
    do {
      try client.setFanRPMSync(UInt(fanIndex), rpm: Float(rpm), priority: pri)
    } catch let err as SMCXPCConflictError {
      log.debug(
        "smc.set_rpm_preempted fan=\(fanIndex, privacy: .public) reason=\(err.message, privacy: .public)"
      )
    }
  }

  public func setAutoSync(fanIndex: Int) throws {
    let pri = self.priority()
    log.debug(
      "smc.set_auto_sync fan=\(fanIndex, privacy: .public) priority=\(pri, privacy: .public)"
    )
    do {
      try client.setFanAutoSync(UInt(fanIndex), priority: pri)
    } catch let err as SMCXPCConflictError {
      log.debug(
        "smc.set_auto_preempted fan=\(fanIndex, privacy: .public) reason=\(err.message, privacy: .public)"
      )
    }
  }

  public func closeSMCConnectionSync() throws {
    try client.closeSync()
  }

  // MARK: - Async API (tick loop)

  public func setRpm(fanIndex: Int, rpm: Int) async throws {
    let pri = self.priority()
    log.debug(
      "smc.set_rpm fan=\(fanIndex, privacy: .public) rpm=\(rpm, privacy: .public) priority=\(pri, privacy: .public)"
    )
    do {
      try await client.setFanRPM(UInt(fanIndex), rpm: Float(rpm), priority: pri)
    } catch let err as SMCXPCConflictError {
      log.debug(
        "smc.set_rpm_preempted fan=\(fanIndex, privacy: .public) reason=\(err.message, privacy: .public)"
      )
    }
  }

  public func setAuto(fanIndex: Int) async throws {
    let pri = self.priority()
    log.debug(
      "smc.set_auto fan=\(fanIndex, privacy: .public) priority=\(pri, privacy: .public)"
    )
    do {
      try await client.setFanAuto(UInt(fanIndex), priority: pri)
    } catch let err as SMCXPCConflictError {
      log.debug(
        "smc.set_auto_preempted fan=\(fanIndex, privacy: .public) reason=\(err.message, privacy: .public)"
      )
    }
  }
}
