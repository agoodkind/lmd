//
//  MaintenanceRunner.swift
//  lmd-maintenance
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-10-25.
//  Copyright © 2026, all rights reserved.
//

import Foundation
import SwiftMkCore

// MARK: - MaintenanceRunner

enum MaintenanceRunner {
  static func run(_ arguments: [String]) throws {
    Output.debug("maintenance.runner argument_count=\(arguments.count)")
    try requireMaintenanceCondition(
      arguments.count == 1, "Usage: prepare-runner DEVELOPER_DIRECTORY")
    let environment = ProcessInfo.processInfo.environment
    try requireMaintenanceCondition(
      environment["GITHUB_ACTIONS"] == "true",
      "Run prepare-runner on an ephemeral GitHub Actions runner.")
    guard let environmentPath = environment["GITHUB_ENV"], !environmentPath.isEmpty else {
      throw MaintenanceError.failure("Set GITHUB_ENV to the action environment file.")
    }
    let developerDirectory = arguments[0]
    try requireMaintenanceCondition(
      developerDirectory.hasPrefix("/") && !developerDirectory.contains("\n"),
      "Specify an absolute Xcode developer directory.")
    _ = try checked("sudo", ["xcode-select", "--switch", developerDirectory])
    let selected = try checked(
      "/usr/bin/env", ["-u", "DEVELOPER_DIR", "xcode-select", "--print-path"])
    try requireMaintenanceCondition(
      selected == developerDirectory, "The runner selected a different Xcode.")
    _ = try checked("xcrun", ["--kill-cache"])
    let sdk = try checked("xcrun", ["--sdk", "macosx", "--show-sdk-path"])
    try requireMaintenanceCondition(
      sdk.hasPrefix("/") && !sdk.contains("\n"), "Xcode did not return an SDK path.")
    let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: environmentPath))
    try handle.seekToEnd()
    try handle.write(contentsOf: Data("SDKROOT=\(sdk)\n".utf8))
    try handle.close()
    _ = try checked("xcrun", ["--sdk", "macosx", "--find", "clang++"])
    _ = try checked("g++", ["--version"])
  }

  private static func checked(_ executable: String, _ arguments: [String]) throws -> String {
    Output.debug("maintenance.runner_process argument_count=\(arguments.count)")
    let result = Shell.run(executable, arguments)
    try requireMaintenanceCondition(
      result.status == 0, "\(executable) failed with status \(result.status): \(result.stderr)")
    Output.log(result.stdout)
    return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
  }
}
