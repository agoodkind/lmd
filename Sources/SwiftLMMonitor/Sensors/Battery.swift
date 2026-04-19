//
//  Battery.swift
//  SwiftLMMonitor
//
//  Created by Alex Goodkind <alex@goodkind.io> on 2026-04-18.
//  Copyright © 2026
//

import AppLogger
import Foundation

private let log = AppLogger.logger(category: "BatterySensor")

// MARK: - Battery

/// Battery and power-adapter state parsed from `pmset -g batt`.
public struct BatterySnapshot: Sendable, Equatable {
  /// Charge percentage in 0...100.
  public let percent: Int
  /// `"charging"`, `"ac_not_charging"`, `"battery"`, or `"unknown"`.
  public let acState: String
  /// Reported power source name (e.g. `"AC Power"`, `"Battery"`).
  public let source: String
}

public enum Battery {
  public static func read() -> BatterySnapshot {
    parse(runCaptureStdout("/usr/bin/pmset", arguments: ["-g", "batt"]))
  }

  /// Authoritative signed battery power in watts.
  ///
  /// Positive = energy entering the battery (charging).
  /// Negative = energy leaving the battery (discharging).
  /// `nil` if ioreg didn't expose the required fields.
  ///
  /// Sourced from AppleSmartBattery.InstantAmperage × Voltage. This is
  /// the only reading we trust for direction; pmset's "charging" label
  /// lags instantaneous flow and SMC's PPBR sign convention varies.
  public static func signedWatts() -> Double? {
    parseSignedWatts(runCaptureStdout("/usr/sbin/ioreg", arguments: ["-rn", "AppleSmartBattery"]))
  }

  /// Parse ioreg AppleSmartBattery output for signed battery power.
  /// Exposed for tests.
  public static func parseSignedWatts(_ text: String) -> Double? {
    var amperageMilliAmps: Int64?
    var voltageMilliVolts: Int64?
    for raw in text.split(separator: "\n") {
      let line = String(raw)
      if line.contains("\"InstantAmperage\""),
         let r = line.range(of: #"=\s*(\d+)"#, options: .regularExpression) {
        let s = String(line[r])
          .replacingOccurrences(of: "=", with: "")
          .trimmingCharacters(in: .whitespaces)
        if let n = UInt64(s) {
          amperageMilliAmps = Int64(bitPattern: n)
        }
      }
      if line.contains("\"Voltage\""),
         !line.contains("Pack"),
         !line.contains("Cell"),
         let r = line.range(of: #"=\s*(\d+)"#, options: .regularExpression) {
        let s = String(line[r])
          .replacingOccurrences(of: "=", with: "")
          .trimmingCharacters(in: .whitespaces)
        voltageMilliVolts = Int64(s)
      }
    }
    guard let mA = amperageMilliAmps, let mV = voltageMilliVolts else { return nil }
    return (Double(mA) * Double(mV)) / 1_000_000
  }

  /// Parse `pmset -g batt` output. Exposed for tests.
  public static func parse(_ text: String) -> BatterySnapshot {
    if text.isEmpty {
      return BatterySnapshot(percent: 0, acState: "unknown", source: "unknown")
    }
    var source = "unknown"
    if let first = text.split(separator: "\n").first,
       let range = first.range(of: "'[^']+'", options: .regularExpression) {
      source = String(first[range]).trimmingCharacters(in: CharacterSet(charactersIn: "'"))
    }
    var percent = 0
    if let match = text.range(of: #"(\d+)%"#, options: .regularExpression) {
      let s = String(text[match]).trimmingCharacters(in: CharacterSet(charactersIn: "%"))
      percent = Int(s) ?? 0
    }
    var acState = "battery"
    // "discharging" contains "charging" as a substring, so check that
    // specific token first. Otherwise look for ";\s*charging".
    let isCharging = text.range(of: #";\s*charging"#, options: .regularExpression) != nil
    if isCharging {
      acState = "charging"
    } else if text.contains("AC Power") || text.contains("AC attached") {
      acState = "ac_not_charging"
    }
    return BatterySnapshot(percent: percent, acState: acState, source: source)
  }
}
