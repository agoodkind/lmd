//
//  VMStat.swift
//  SwiftLMMonitor
//
//  Created by Alex Goodkind <alex@goodkind.io> on 2026-04-18.
//  Copyright © 2026
//

import AppLogger
import Foundation

private let log = AppLogger.logger(category: "VMStatSensor")

// MARK: - VM stat reading

/// Values parsed from `/usr/bin/vm_stat` output.
public struct VMStatSnapshot: Sendable, Equatable {
  public var pageouts: Int64
  public var pageins: Int64
  public var compressions: Int64
  public var decompressions: Int64
  public var pagesCompressed: Int64
  public var pagesFree: Int64
  public var pagesActive: Int64
  public var pagesInactive: Int64
  public var pagesWired: Int64
}

/// Read `/usr/bin/vm_stat` and parse the subset of counters we care about.
public enum VMStat {
  public static func read() -> VMStatSnapshot {
    parse(runCaptureStdout("/usr/bin/vm_stat", arguments: []))
  }

  /// Parse raw vm_stat output. Exposed for tests.
  public static func parse(_ text: String) -> VMStatSnapshot {
    func field(_ name: String) -> Int64 {
      for line in text.split(separator: "\n") where line.contains(name) {
        let after = line.split(separator: ":").last.map(String.init) ?? ""
        let digits = after.filter { $0.isNumber }
        return Int64(digits) ?? 0
      }
      return 0
    }
    return VMStatSnapshot(
      pageouts: field("Pageouts"),
      pageins: field("Pageins"),
      compressions: field("Compressions"),
      decompressions: field("Decompressions"),
      pagesCompressed: field("Pages stored in compressor"),
      pagesFree: field("Pages free"),
      pagesActive: field("Pages active"),
      pagesInactive: field("Pages inactive"),
      pagesWired: field("Pages wired down")
    )
  }
}
