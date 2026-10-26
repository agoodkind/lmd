//
//  MaintenanceRecording.swift
//  lmd-maintenance
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-10-25.
//  Copyright © 2026, all rights reserved.
//

import Foundation
import SwiftMkCore

// MARK: - MaintenanceRecording

enum MaintenanceRecording {
  static func run(_ arguments: [String]) throws {
    Output.debug("maintenance.record argument_count=\(arguments.count)")
    var forwarded = arguments
    var quiet = false
    if forwarded.first == "--quiet" {
      quiet = true
      forwarded.removeFirst()
    }
    let requiredArgumentCount = 3
    let executableArgumentIndex = 2
    try requireMaintenanceCondition(
      forwarded.count >= requiredArgumentCount && forwarded[0] == "--log",
      "Usage: record [--quiet] --log PATH EXECUTABLE [ARGUMENT...]")
    let log = URL(fileURLWithPath: forwarded[1]).standardizedFileURL
    try FileManager.default.createDirectory(
      at: log.deletingLastPathComponent(), withIntermediateDirectories: true)
    let executable = forwarded[executableArgumentIndex]
    let commandArguments = Array(forwarded.dropFirst(requiredArgumentCount))
    let status: Int32
    if quiet {
      status = Shell.runWritingOutput(executable, commandArguments, toFile: log.path)
    } else {
      let result = Shell.runForwardingAndCapturingStreaming(executable, commandArguments)
      try Data(result.combined.utf8).write(to: log, options: .atomic)
      status = result.status
    }
    try requireMaintenanceCondition(
      status == 0,
      "Command failed with status \(status). Read \(log.path).")
  }
}
