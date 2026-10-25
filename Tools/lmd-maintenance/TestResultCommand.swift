//
//  TestResultCommand.swift
//  lmd-maintenance
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-10-25.
//  Copyright © 2026, all rights reserved.
//

import Foundation
import SwiftMkCore

enum TestResultCommand {
  static func run(_ arguments: [String]) throws {
    guard let mode = arguments.first else {
      throw MaintenanceError.failure("Specify swiftpm or xcode test result validation.")
    }
    Output.debug("test_results.verification_started mode=\(mode)")
    let remaining = Array(arguments.dropFirst())
    let summaries: [String]
    switch mode {
    case "swiftpm":
      let requiredArgumentCount = 3
      try requireMaintenanceCondition(
        remaining.count >= requiredArgumentCount,
        "Usage: verify-test-results swiftpm LOG DISCOVERY CLASS_OR_MODULE [CLASS_OR_MODULE...]")
      summaries = try TestResultVerifier.verifySwiftPM(
        log: URL(fileURLWithPath: remaining[0]),
        discovery: URL(fileURLWithPath: remaining[1]),
        selectors: Array(remaining.dropFirst(requiredArgumentCount - 1)))
    case "xcode":
      let requiredArgumentCount = 2
      try requireMaintenanceCondition(
        remaining.count >= requiredArgumentCount,
        "Usage: verify-test-results xcode REPORT_JSON SUITE_PATH [SUITE_PATH...]")
      summaries = try TestResultVerifier.verifyXcode(
        report: URL(fileURLWithPath: remaining[0]),
        selectors: Array(remaining.dropFirst()))
    default:
      throw MaintenanceError.failure("Select swiftpm or xcode test result validation.")
    }
    for summary in summaries {
      Output.log(summary)
    }
  }
}
