//
//  PowerMonitor.swift
//  SwiftLMMonitor
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-06-04.
//  Copyright © 2026, all rights reserved.
//

import AppLogger
import Dispatch
import Foundation

private let log = AppLogger.logger(category: "PowerMonitor")

// MARK: - Power monitor

/// Watches battery charge and Low Power Mode and reports a graded throttle
/// ``Level``.
///
/// There are three levels. `mild` is a plain threshold band: it applies while
/// charge sits in `engagePct < charge <= mildEngagePct` and turns off above
/// `mildEngagePct`, with no memory. `hard` is the stop level. Low Power Mode
/// always forces that stop immediately. Outside Low Power Mode, battery-driven
/// `hard` keeps its hysteresis: once engaged at `charge <= engagePct`, it holds
/// until charge recovers to `resumePct`.
///
/// One escape lifts the battery-driven `hard`: when `highPowerOverride` is set
/// and the reading is on AC power in High Power energy mode, the hard stop and
/// its hysteresis hold are skipped. The `mild` band still applies while charge
/// is low, and Low Power Mode still forces `hard`.
///
/// This type stays in `SwiftLMMonitor`, which depends only on `AppLogger`, so it
/// keeps its own `Level` enum; the broker translates it to the shared
/// `PowerThrottleLevel` when wiring the router.
public final class PowerMonitor: @unchecked Sendable {
  public enum Level: Int, Sendable, Equatable {
    case none = 0
    case mild = 1
    case hard = 2
  }

  public struct Reading: Sendable, Equatable {
    public let percent: Int
    public let isLowPowerModeEnabled: Bool
    /// True when the machine is drawing from the power adapter.
    public let isOnACPower: Bool
    /// True when the active macOS Energy Mode is High Power.
    public let isHighPowerMode: Bool

    public init(
      percent: Int,
      isLowPowerModeEnabled: Bool,
      isOnACPower: Bool = false,
      isHighPowerMode: Bool = false
    ) {
      self.percent = percent
      self.isLowPowerModeEnabled = isLowPowerModeEnabled
      self.isOnACPower = isOnACPower
      self.isHighPowerMode = isHighPowerMode
    }
  }

  enum HardReason: Sendable, Equatable {
    case battery
    case lowPowerMode
  }

  struct State: Sendable, Equatable {
    let level: Level
    let hardReason: HardReason?

    static let steady = State(level: .none, hardReason: nil)
  }

  public struct Config: Sendable {
    /// Engage the `hard` stop when charge is at or below this percent. Zero
    /// disables the monitor.
    public let engagePct: Int
    /// Engage `mild` when charge is at or below this percent (but above
    /// `engagePct`). Must sit above `engagePct` and below `resumePct`.
    public let mildEngagePct: Int
    /// Release battery-driven `hard` only once charge recovers to or above this
    /// percent. The gap from `engagePct` to `resumePct` is the anti-flap dead
    /// band for the battery stop.
    public let resumePct: Int
    /// When true, being on AC power in High Power energy mode lifts the
    /// battery-driven `hard` stop. The `mild` band still applies while charge is
    /// low, and Low Power Mode still forces `hard`.
    public let highPowerOverride: Bool
    public let intervalSeconds: Double

    public init(
      engagePct: Int,
      mildEngagePct: Int,
      resumePct: Int,
      highPowerOverride: Bool = true,
      intervalSeconds: Double = 15
    ) {
      self.engagePct = engagePct
      self.mildEngagePct = mildEngagePct
      self.resumePct = resumePct
      self.highPowerOverride = highPowerOverride
      self.intervalSeconds = intervalSeconds
    }

    /// True when no engage threshold is configured, so the monitor never runs.
    public var isDisabled: Bool { engagePct <= 0 }
  }

  private let config: Config
  private let reading: @Sendable () -> Reading
  private let lock = NSLock()
  private var state: State = .steady
  private var onChangeHandler: (@Sendable (Level) -> Void)?
  private var stopRequested = false
  private var started = false

  /// `reading` returns the current battery charge and Low Power Mode state.
  @preconcurrency
  public init(config: Config, reading: @escaping @Sendable () -> Reading) {
    self.config = config
    self.reading = reading
  }

  /// Install the handler that runs whenever the level changes.
  @preconcurrency
  public func setOnChange(_ handler: @escaping @Sendable (Level) -> Void) {
    lock.lock()
    onChangeHandler = handler
    lock.unlock()
  }

  /// The most recent throttle level.
  public func currentLevel() -> Level {
    lock.lock()
    defer { lock.unlock() }
    return state.level
  }

  /// Start polling. A disabled config or a second call is a no-op.
  public func start() {
    if config.isDisabled {
      log.notice("power.monitor_disabled")
      return
    }
    lock.lock()
    if started {
      lock.unlock()
      return
    }
    started = true
    lock.unlock()

    reevaluate()
    log.notice(
      """
      power.monitor_started engage_pct=\(self.config.engagePct, privacy: .public) \
      mild_pct=\(self.config.mildEngagePct, privacy: .public) \
      resume_pct=\(self.config.resumePct, privacy: .public)
      """
    )
    DispatchQueue.global(qos: .utility).async { [weak self] in
      self?.runLoop()
    }
  }

  /// Stop polling.
  public func stop() {
    lock.lock()
    stopRequested = true
    lock.unlock()
  }

  /// Force an immediate recompute from the current reading.
  public func reevaluate() {
    guard config.isDisabled == false else {
      return
    }
    applyReading(reading())
  }

  private func runLoop() {
    while true {
      lock.lock()
      let stop = stopRequested
      lock.unlock()
      if stop {
        return
      }
      autoreleasepool {
        sampleOnce()
      }
      Thread.sleep(forTimeInterval: config.intervalSeconds)
    }
  }

  private func sampleOnce() {
    applyReading(reading())
  }

  private func applyReading(_ reading: Reading) {
    lock.lock()
    let previous = state
    let next = PowerMonitor.nextState(reading: reading, config: config, previous: previous)
    state = next
    let handler = onChangeHandler
    lock.unlock()

    guard next != previous else {
      return
    }
    lock.lock()
    let stillCurrent = (state == next)
    lock.unlock()
    guard stillCurrent else {
      return
    }
    log.notice(
      """
      power.throttle_changed level=\(next.level.rawValue, privacy: .public) \
      percent=\(reading.percent, privacy: .public) \
      low_power_mode=\(reading.isLowPowerModeEnabled, privacy: .public) \
      on_ac=\(reading.isOnACPower, privacy: .public) \
      high_power=\(reading.isHighPowerMode, privacy: .public)
      """
    )
    handler?(next.level)
  }

  // MARK: - Pure state computation (tested directly)

  static func nextState(reading: Reading, config: Config, previous: State) -> State {
    if reading.isLowPowerModeEnabled {
      return State(level: .hard, hardReason: .lowPowerMode)
    }
    // On AC power in High Power energy mode, the operator has opted into full
    // performance while plugged in, so skip the battery hysteresis hold and the
    // hard engage. The mild band below still applies while charge is low.
    let acHighPowerOverride =
      config.highPowerOverride && reading.isOnACPower && reading.isHighPowerMode
    if acHighPowerOverride == false {
      if previous.level == .hard, previous.hardReason == .battery {
        if reading.percent >= config.resumePct {
          return .steady
        }
        return State(level: .hard, hardReason: .battery)
      }
      if reading.percent <= config.engagePct {
        return State(level: .hard, hardReason: .battery)
      }
    }
    if reading.percent <= config.mildEngagePct {
      return State(level: .mild, hardReason: nil)
    }
    return .steady
  }

  deinit {
    stop()
  }
}
