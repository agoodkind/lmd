//
//  MemoryPressure.swift
//  SwiftLMMonitor
//
//  Created by Alex Goodkind <alex@goodkind.io> on 2026-04-18.
//  Copyright © 2026
//

import AppLogger
import Foundation

private let log = AppLogger.logger(category: "MemoryPressureSensor")

// MARK: - Memory pressure

/// Wrapper over the macOS `memory_pressure` binary.
public enum MemoryPressure {
  /// Percentage of memory reported as "System-wide memory free".
  public static func freePercent() -> Int {
    parseFreePercent(runCaptureStdout("/usr/bin/memory_pressure", arguments: []))
  }

  public static func parseFreePercent(_ text: String) -> Int {
    for line in text.split(separator: "\n") where line.contains("System-wide memory free percentage") {
      let digits = line.filter { $0.isNumber }
      return Int(digits) ?? 0
    }
    return 0
  }
}
