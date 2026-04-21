//
//  LiveFanSMCController.swift
//  SwiftLMRuntime
//
//  Created by Alex Goodkind <alex@goodkind.io> on 2026-04-20.
//  Copyright © 2026
//

import AppLogger
import Foundation
import SMCDClient

/// Routes fan control through the user space smcd arbiter.
///
/// Holds a single `SMCDClient` for the lifetime of the daemon. smcd in
/// turn owns the privileged XPC connection to smcfanhelper. Every write
/// carries a priority; the default priority is set at init. A preempted
/// write (`SMCDConflictError`) is logged at debug and swallowed so the
/// state machine's next tick retries without propagating the error.
public final class LiveFanSMCController: FanSMCControlling, @unchecked Sendable {
  private let log = AppLogger.logger(category: "LiveFanSMCController")
  private let client: SMCDClient
  private let priorityLock = NSLock()
  private var currentPriority: Int

  /// `throws` is retained for source compatibility with `try?` at call sites
  /// even though no current code path throws. The old SMCFanXPCClient init
  /// could throw on XPC proxy setup; SMCDClient does not.
  public init(clientName: String = "lmd-serve", defaultPriority: Int = 50) throws {
    self.client = SMCDClient(
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

  // MARK: - Synchronous API

  /// smcd manages its own helper session; no per client open is needed.
  public func smcOpenIfNeededSync() throws {}

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
    } catch let err as SMCDConflictError {
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
    } catch let err as SMCDConflictError {
      log.debug(
        "smc.set_auto_preempted fan=\(fanIndex, privacy: .public) reason=\(err.message, privacy: .public)"
      )
    }
  }

  /// smcd owns the helper session; no explicit close on our side.
  public func closeSMCConnectionSync() throws {}

  // MARK: - Async API

  public func setRpm(fanIndex: Int, rpm: Int) async throws {
    let pri = self.priority()
    log.debug(
      "smc.set_rpm fan=\(fanIndex, privacy: .public) rpm=\(rpm, privacy: .public) priority=\(pri, privacy: .public)"
    )
    do {
      try await client.setFanRPM(UInt(fanIndex), rpm: Float(rpm), priority: pri)
    } catch let err as SMCDConflictError {
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
    } catch let err as SMCDConflictError {
      log.debug(
        "smc.set_auto_preempted fan=\(fanIndex, privacy: .public) reason=\(err.message, privacy: .public)"
      )
    }
  }
}
