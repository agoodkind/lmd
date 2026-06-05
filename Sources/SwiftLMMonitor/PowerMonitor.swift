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

/// Watches battery charge and reports a throttle ``Level`` with a wide
/// engage/resume hysteresis band, so the level cannot flap.
///
/// It engages the throttle when charge falls to `engagePct` and holds it until
/// charge recovers all the way to `resumePct`. Anywhere in the band between the
/// two thresholds it holds the current level, so a battery hovering or slowly
/// recharging never bounces the throttle on and off. This is a Schmitt trigger:
/// one low threshold to turn on, one high threshold to turn off, a large dead
/// band in between.
///
/// This type stays in `SwiftLMMonitor`, which depends only on `AppLogger`, so it
/// keeps its own `Level` enum; the broker translates it to the shared
/// `PowerThrottleLevel` when wiring the router.
public final class PowerMonitor: @unchecked Sendable {
  public enum Level: Int, Sendable, Equatable {
    case none = 0
    case hard = 1
  }

  public struct Config: Sendable {
    /// Engage the throttle when charge is at or below this percent. Zero
    /// disables the monitor.
    public let engagePct: Int
    /// Release the throttle only once charge recovers to or above this percent.
    /// The gap from `engagePct` to `resumePct` is the anti-flap dead band.
    public let resumePct: Int
    public let intervalSeconds: Double

    public init(engagePct: Int, resumePct: Int, intervalSeconds: Double = 15) {
      self.engagePct = engagePct
      self.resumePct = resumePct
      self.intervalSeconds = intervalSeconds
    }

    /// True when no engage threshold is configured, so the monitor never runs.
    public var isDisabled: Bool { engagePct <= 0 }
  }

  private let config: Config
  private let reading: @Sendable () -> Int
  private let lock = NSLock()
  private var level: Level = .none
  private var onChangeHandler: (@Sendable (Level) -> Void)?
  private var stopRequested = false
  private var started = false

  /// `reading` returns the current battery charge percent (0...100).
  public init(config: Config, reading: @escaping @Sendable () -> Int) {
    self.config = config
    self.reading = reading
  }

  /// Install the handler that runs whenever the level changes.
  public func setOnChange(_ handler: @escaping @Sendable (Level) -> Void) {
    lock.lock()
    onChangeHandler = handler
    lock.unlock()
  }

  /// The most recent throttle level.
  public func currentLevel() -> Level {
    lock.lock()
    defer { lock.unlock() }
    return level
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

    log.notice(
      """
      power.monitor_started engage_pct=\(self.config.engagePct, privacy: .public) \
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
    let percent = reading()
    lock.lock()
    let previous = level
    let next = PowerMonitor.nextLevel(percent: percent, config: config, previous: previous)
    level = next
    let handler = onChangeHandler
    lock.unlock()

    guard next != previous else {
      return
    }
    log.notice(
      """
      power.throttle_changed level=\(next.rawValue, privacy: .public) \
      percent=\(percent, privacy: .public)
      """
    )
    handler?(next)
  }

  // MARK: - Pure level computation (tested directly)

  /// Schmitt trigger: engage at or below `engagePct`, release at or above
  /// `resumePct`, and hold the current level anywhere in the band between. The
  /// wide band is the whole anti-flap mechanism: the charge must cross all the
  /// way from one threshold to the other before the level changes.
  static func nextLevel(percent: Int, config: Config, previous: Level) -> Level {
    if percent <= config.engagePct {
      return .hard
    }
    if percent >= config.resumePct {
      return .none
    }
    return previous
  }

  deinit {
    stop()
  }
}
