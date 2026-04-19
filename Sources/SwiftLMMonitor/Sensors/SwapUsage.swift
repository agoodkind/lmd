//
//  SwapUsage.swift
//  SwiftLMMonitor
//
//  Created by Alex Goodkind <alex@goodkind.io> on 2026-04-18.
//  Copyright © 2026
//

import AppLogger
import Foundation

private let log = AppLogger.logger(category: "SwapSensor")

// MARK: - Swap usage

/// Swap pool sizes as strings with unit suffix.
///
/// The values are kept as strings so the original unit letter (`M`, `G`)
/// is preserved verbatim for log correlation.
public struct SwapUsageSnapshot: Sendable, Equatable {
  public let used: String
  public let total: String
}

public enum SwapUsage {
  /// Read `sysctl vm.swapusage`.
  public static func read() -> SwapUsageSnapshot {
    parse(runCaptureStdout("/usr/sbin/sysctl", arguments: ["-n", "vm.swapusage"]))
  }

  /// Parse raw `vm.swapusage` output. Exposed for tests.
  public static func parse(_ text: String) -> SwapUsageSnapshot {
    var used = "0"
    var total = "0"
    let fields = text.split(separator: " ").map(String.init)
    for (i, f) in fields.enumerated() {
      if f == "used" && i + 2 < fields.count { used = fields[i + 2] }
      if f == "total" && i + 2 < fields.count { total = fields[i + 2] }
    }
    return SwapUsageSnapshot(used: used, total: total)
  }
}

// MARK: - Swap files

/// Count real swap files on disk under `/private/var/vm`.
public enum SwapFiles {
  public static func count() -> Int {
    guard let contents = try? FileManager.default.contentsOfDirectory(atPath: "/private/var/vm") else {
      return 0
    }
    return contents.filter { $0.hasPrefix("swapfile") }.count
  }
}

// MARK: - Load average

public enum LoadAverage {
  /// Read the 1-minute load average via `sysctl vm.loadavg`.
  public static func oneMinute() -> Double {
    parseOneMinute(runCaptureStdout("/usr/sbin/sysctl", arguments: ["-n", "vm.loadavg"]))
  }

  public static func parseOneMinute(_ text: String) -> Double {
    let fields = text.split(separator: " ").map(String.init)
    guard fields.count >= 2 else { return 0 }
    return Double(fields[1]) ?? 0
  }
}
