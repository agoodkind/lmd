//
//  MemoryPressureMonitor.swift
//  SwiftLMMonitor
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-05-31.
//  Copyright © 2026, all rights reserved.
//

import AppLogger
import Dispatch
import Foundation

private let log = AppLogger.logger(category: "MemoryPressureMonitor")

// MARK: - Memory pressure monitor

/// Watches the system memory-pressure condition through the native
/// `DispatchSource` memory-pressure source.
///
/// The source delivers events as the condition changes, while callers read the
/// level on demand. This monitor bridges the two: it starts one source,
/// remembers the latest level behind a lock, answers `currentLevel()` for the
/// router's probe, and runs an optional handler whenever the level changes so
/// the broker can react the moment memory turns critical.
public final class MemoryPressureMonitor: @unchecked Sendable {
  public enum Level: Int, Sendable {
    case normal = 0
    case warning = 1
    case critical = 2
  }

  private let lock = NSLock()
  private var level: Level = .normal
  private var onChangeHandler: (@Sendable (Level) -> Void)?
  private var source: DispatchSourceMemoryPressure?

  public init() {}

  /// Install the handler that runs whenever the pressure level changes.
  @preconcurrency
  public func setOnChange(_ handler: @escaping @Sendable (Level) -> Void) {
    lock.lock()
    onChangeHandler = handler
    lock.unlock()
  }

  /// The most recent pressure level reported by the system.
  public func currentLevel() -> Level {
    lock.lock()
    defer { lock.unlock() }
    return level
  }

  /// Start watching. Safe to call once; later calls are ignored.
  public func start() {
    lock.lock()
    let alreadyStarted = source != nil
    lock.unlock()
    if alreadyStarted {
      return
    }

    let pressureSource = DispatchSource.makeMemoryPressureSource(
      eventMask: [.normal, .warning, .critical],
      queue: DispatchQueue.global(qos: .utility)
    )
    pressureSource.setEventHandler { [weak self] in
      guard let self else {
        return
      }
      let event = pressureSource.data
      let newLevel: Level
      if event.contains(.critical) {
        newLevel = .critical
      } else if event.contains(.warning) {
        newLevel = .warning
      } else {
        newLevel = .normal
      }
      update(newLevel)
    }

    lock.lock()
    source = pressureSource
    lock.unlock()
    pressureSource.activate()
    log.notice("memory_pressure.monitor_started")
  }

  /// Stop watching and release the source.
  public func stop() {
    lock.lock()
    let pressureSource = source
    source = nil
    lock.unlock()
    pressureSource?.cancel()
  }

  private func update(_ newLevel: Level) {
    lock.lock()
    let changed = newLevel != level
    level = newLevel
    let handler = onChangeHandler
    lock.unlock()

    guard changed else {
      return
    }
    log.notice("memory_pressure.level_changed level=\(newLevel.rawValue, privacy: .public)")
    handler?(newLevel)
  }

  deinit {
    source?.cancel()
  }
}
