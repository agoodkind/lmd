//
//  MonitorTab.swift
//  SwiftLMTUI
//
//  Created by Alex Goodkind <alex@goodkind.io> on 2026-04-18.
//  Copyright © 2026
//
//  Minimal MonitorTab that renders a snapshot dict (the kind `swiftmon`
//  writes to memory.jsonl) as a thermal / power / battery summary. Real
//  render logic in `swifttop/main.swift` is richer; this is the portable
//  library version used when hosting the monitor inside the tabbed TUI.
//

import AppLogger
import Foundation

private let log = AppLogger.logger(category: "MonitorTab")

// MARK: - Monitor snapshot

/// A minimal thermal / power / battery sample, parsed from one memory.jsonl
/// row. All values are stored pre-formatted so the tab is pure rendering.
public struct MonitorSnapshot: Sendable {
  public let cpuTempC: Double
  public let gpuTempC: Double
  public let cpuPercent: Double
  public let gpuPercent: Double
  public let systemPowerW: Double
  public let ramUsedGB: Double
  public let pressureFreePct: Int
  public let battPct: Int
  public let battWattsSigned: Double
  public let acState: String

  public init(
    cpuTempC: Double, gpuTempC: Double,
    cpuPercent: Double, gpuPercent: Double,
    systemPowerW: Double, ramUsedGB: Double,
    pressureFreePct: Int,
    battPct: Int, battWattsSigned: Double, acState: String
  ) {
    self.cpuTempC = cpuTempC
    self.gpuTempC = gpuTempC
    self.cpuPercent = cpuPercent
    self.gpuPercent = gpuPercent
    self.systemPowerW = systemPowerW
    self.ramUsedGB = ramUsedGB
    self.pressureFreePct = pressureFreePct
    self.battPct = battPct
    self.battWattsSigned = battWattsSigned
    self.acState = acState
  }

  public static let empty = MonitorSnapshot(
    cpuTempC: 0, gpuTempC: 0,
    cpuPercent: 0, gpuPercent: 0,
    systemPowerW: 0, ramUsedGB: 0,
    pressureFreePct: 100,
    battPct: 100, battWattsSigned: 0, acState: "unknown"
  )

  /// Decode from a parsed JSONL row. Any missing field defaults gracefully.
  public static func from(json: [String: Any]) -> MonitorSnapshot {
    MonitorSnapshot(
      cpuTempC: (json["cpu_temp_c"] as? Double) ?? 0,
      gpuTempC: (json["gpu_temp_c"] as? Double) ?? 0,
      cpuPercent: (json["cpu_pct"] as? Double) ?? 0,
      gpuPercent: (json["gpu_pct"] as? Double) ?? 0,
      systemPowerW: (json["sys_power_w"] as? Double) ?? 0,
      ramUsedGB: (json["ram_used_gb"] as? Double) ?? 0,
      pressureFreePct: (json["pressure_free_pct"] as? Int) ?? 100,
      battPct: (json["batt_pct"] as? Int) ?? 100,
      battWattsSigned: (json["batt_watts_signed"] as? Double) ?? 0,
      acState: (json["ac_state"] as? String) ?? "unknown"
    )
  }
}

// MARK: - MonitorTab

/// Read-only tab that summarizes system state. A host (e.g. the future
/// `lmd tui`) sets `snapshot` before calling `render`. Does not poll IO
/// itself. That stays in the host process so tests can drive it.
public final class MonitorTab: Tab {
  public let label = "monitor"
  public let title = "monitor"
  public var snapshot: MonitorSnapshot = .empty

  public init() {}

  public func render(into buffer: ScreenBuffer, contentRows rows: ClosedRange<Int>) {
    var row = rows.lowerBound
    func write(_ text: String) {
      if row <= rows.upperBound {
        buffer.put(row: row, text)
        row += 1
      }
    }

    write("\(Theme.head)THERMAL & LOAD\(Ansi.reset)")
    write(Row.three(
      "\(Theme.label)cpu temp\(Ansi.reset)",
      "\(Theme.tempColor(snapshot.cpuTempC))\(String(format: "%.1f°C", snapshot.cpuTempC))\(Ansi.reset)",
      ""
    ))
    write(Row.three(
      "\(Theme.label)gpu temp\(Ansi.reset)",
      "\(Theme.tempColor(snapshot.gpuTempC))\(String(format: "%.1f°C", snapshot.gpuTempC))\(Ansi.reset)",
      ""
    ))
    write(Row.three(
      "\(Theme.label)cpu use\(Ansi.reset)",
      "\(Theme.text)\(String(format: "%.1f%%", snapshot.cpuPercent))\(Ansi.reset)",
      ""
    ))
    write(Row.three(
      "\(Theme.label)gpu use\(Ansi.reset)",
      "\(Theme.text)\(String(format: "%.1f%%", snapshot.gpuPercent))\(Ansi.reset)",
      ""
    ))
    write("")

    write("\(Theme.head)MEMORY\(Ansi.reset)")
    write(Row.three(
      "\(Theme.label)ram used\(Ansi.reset)",
      "\(Theme.text)\(String(format: "%.1f GB", snapshot.ramUsedGB))\(Ansi.reset)",
      ""
    ))
    write(Row.three(
      "\(Theme.label)pressure\(Ansi.reset)",
      "\(Theme.text)\(snapshot.pressureFreePct)% free\(Ansi.reset)",
      ""
    ))
    write("")

    write("\(Theme.head)BATTERY\(Ansi.reset)")
    write(Row.three(
      "\(Theme.label)charge\(Ansi.reset)",
      "\(Theme.text)\(snapshot.battPct)%\(Ansi.reset)",
      "\(Theme.dim)\(snapshot.acState)\(Ansi.reset)"
    ))
    let watts = snapshot.battWattsSigned
    let wattsLabel: String
    if watts > 0.1 {
      wattsLabel = "\(Theme.ok)+\(String(format: "%.1f W", watts))\(Ansi.reset) \(Theme.dim)charging\(Ansi.reset)"
    } else if watts < -0.1 {
      wattsLabel = "\(Theme.bad)\(String(format: "%.1f W", watts))\(Ansi.reset) \(Theme.dim)discharging\(Ansi.reset)"
    } else {
      wattsLabel = "\(Theme.dim)0.0 W idle\(Ansi.reset)"
    }
    write(Row.three("\(Theme.label)flow\(Ansi.reset)", wattsLabel, ""))
  }

  public func handle(_ input: TabInput) -> TabAction {
    switch input {
    case .key(.quit): return .quit
    default: return .none
    }
  }
}
