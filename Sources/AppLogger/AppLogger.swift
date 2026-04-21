//
//  AppLogger.swift
//  AppLogger
//
//  Created by Alex Goodkind <alex@goodkind.io> on 2026-04-18.
//  Copyright © 2026
//
//  Apple-native unified logging wrapper. Single source of truth for
//  every `os.Logger` handle in the lmd ecosystem.
//
//  Usage
//  -----
//  In each executable's `main.swift`:
//      import AppLogger
//      AppLogger.bootstrap(subsystem: "io.goodkind.lmd")
//
//  In each source file that emits events:
//      private let log = AppLogger.logger(category: "ModelRouter")
//      log.notice("model.loaded id=\(id, privacy: .public)")
//
//  Direct `Logger(subsystem:...)` construction is forbidden elsewhere.
//  `make log-audit` enforces this. The bridge in
//  `SwiftLogBridge.swift` routes transitive `swift-log` traffic
//  (Hummingbird, async-http-client, swift-nio) through the same
//  subsystem, so one `log stream --subsystem io.goodkind.lmd` captures
//  everything.
//

import Foundation
import Logging
@_exported import os

/// Namespace for the unified logging helper.
///
/// `AppLogger.bootstrap` must be called exactly once at process start.
/// Subsequent calls are no-ops. Callers then use `AppLogger.logger(category:)`
/// to obtain a per-category `os.Logger` handle and `AppLogger.signposter(category:)`
/// to obtain a performance signposter.
public enum AppLogger {
  // MARK: - State

  /// Backing subsystem recorded by ``bootstrap``. Guarded by `stateQueue`.
  nonisolated(unsafe) private static var _subsystem: String?
  private static let stateQueue = DispatchQueue(label: "io.goodkind.applogger.state")

  /// The bootstrapped subsystem. Defaults to `"io.goodkind.unknown"` if
  /// a logger is requested before ``bootstrap`` runs. In practice this
  /// should never happen because `bootstrap` is the first executable
  /// statement in every target's `main.swift`.
  private static var subsystem: String {
    stateQueue.sync { _subsystem ?? "io.goodkind.unknown" }
  }

  // MARK: - Bootstrap

  /// Record the subsystem and install the swift-log to os.Logger bridge.
  ///
  /// Idempotent: only the first call takes effect. Never throws. There
  /// is no failure path in Apple's unified logging that could be
  /// reported here.
  public static func bootstrap(subsystem: String) {
    let installed = stateQueue.sync { () -> Bool in
      if _subsystem != nil { return false }
      _subsystem = subsystem
      return true
    }
    guard installed else { return }
    // Route every swift-log consumer through os.Logger. Tests rely on
    // this so Hummingbird's request logs land under the same predicate.
    LoggingSystem.bootstrap { label in
      SwiftLogToOSLogBackend(subsystem: subsystem, category: label)
    }
  }

  // MARK: - Factories

  /// Obtain a categorized `os.Logger`. One handle per source file is the
  /// convention; do not share across modules.
  public static func logger(category: String) -> os.Logger {
    os.Logger(subsystem: subsystem, category: category)
  }

  /// Category string aligned with Go `gklog` style `component` + `subcomponent` attributes.
  ///
  /// Example: `category(component: "Broker", subcomponent: "client")` → `"Broker.client"`.
  /// Use when you want structured parity with JSON logs that carry both fields.
  public static func category(component: String, subcomponent: String) -> String {
    "\(component).\(subcomponent)"
  }

  /// `os.Logger` whose category is ``category(component:subcomponent:)``.
  public static func logger(component: String, subcomponent: String) -> os.Logger {
    logger(category: category(component: component, subcomponent: subcomponent))
  }

  /// Obtain an `OSSignposter` for performance intervals. All signposts
  /// land under the shared subsystem with a single `Performance`
  /// category so Instruments / `xctrace` filtering stays simple.
  public static func signposter(category: String = "Performance") -> OSSignposter {
    OSSignposter(subsystem: subsystem, category: category)
  }
}
