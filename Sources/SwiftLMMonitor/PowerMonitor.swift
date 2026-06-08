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

/// Watches battery charge and reports a graded throttle ``Level``.
///
/// There are three levels. `mild` is a plain threshold band: it applies while
/// charge sits in `engagePct < charge <= mildEngagePct` and turns off above
/// `mildEngagePct`, with no memory. `hard` is the stop level and is the only one
/// with hysteresis: it engages at `charge <= engagePct` and holds all the way
/// until charge recovers to `resumePct`, so a battery hovering or slowly
/// recharging never bounces the stop on and off. While `hard` is held it
/// overrides `mild`.
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

  public struct Config: Sendable {
    /// Engage the `hard` stop when charge is at or below this percent. Zero
    /// disables the monitor.
    public let engagePct: Int
    /// Engage `mild` when charge is at or below this percent (but above
    /// `engagePct`). Must sit above `engagePct` and below `resumePct`.
    public let mildEngagePct: Int
    /// Release `hard` only once charge recovers to or above this percent. The
    /// gap from `engagePct` to `resumePct` is the anti-flap dead band for the
    /// stop.
    public let resumePct: Int
    public let intervalSeconds: Double

    public init(
      engagePct: Int,
      mildEngagePct: Int,
      resumePct: Int,
      intervalSeconds: Double = 15
    ) {
      self.engagePct = engagePct
      self.mildEngagePct = mildEngagePct
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
  @preconcurrency
  public init(config: Config, reading: @escaping @Sendable () -> Int) {
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

  /// Compute the next level from the live charge and the previous level.
  ///
  /// `hard` is the only level with hysteresis: once engaged at `engagePct` it
  /// holds until charge climbs back to `resumePct`, which is the whole anti-flap
  /// mechanism for the stop, and it overrides `mild` while held. `mild` is a
  /// plain band with no memory, so outside a hard hold the level follows the
  /// live charge: `hard` at or below `engagePct`, `mild` at or below
  /// `mildEngagePct`, otherwise `none`.
  static func nextLevel(percent: Int, config: Config, previous: Level) -> Level {
    if previous == .hard {
      if percent >= config.resumePct {
        return .none
      }
      return .hard
    }
    if percent <= config.engagePct {
      return .hard
    }
    if percent <= config.mildEngagePct {
      return .mild
    }
    return .none
  }

  deinit {
    stop()
  }
}
