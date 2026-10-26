//
//  main.swift
//  lmd-maintenance
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-10-25.
//  Copyright © 2026, all rights reserved.
//

import Foundation
import SwiftMkCore

// MARK: - MaintenanceCommand

enum MaintenanceCommand {
  static func run(_ arguments: [String]) throws {
    Output.debug("maintenance.command argument_count=\(arguments.count)")
    guard let command = arguments.first else {
      throw MaintenanceError.failure(
        "Specify prepare-versions, verify-versions, verify-artifacts, verify-patches, verify-test-results, or record."
      )
    }
    let remaining = Array(arguments.dropFirst())
    switch command {
    case "verify-patches":
      try PatchVerificationCommand.run(remaining)
    case "read-patch-versions":
      try MaintenanceCatalog.run(remaining)
    case "prepare-runner":
      try MaintenanceRunner.run(remaining)
    case "prepare-versions":
      try DependencyVersionsCommand.run(["prepare"] + remaining)
    case "verify-versions":
      try DependencyVersionsCommand.run(["verify"] + remaining)
    case "verify-artifacts":
      try DependencyVersionsCommand.run(["artifacts"] + remaining)
    case "verify-test-results":
      try TestResultCommand.run(remaining)
    case "record":
      try MaintenanceRecording.run(remaining)
    case "sync-upstream":
      try UpstreamSyncCommand.run(remaining)
    case "create-sync-pull-request":
      try UpstreamSyncCommand.createPullRequest(remaining)
    case "bump-dependency":
      try DependencyBumpCommand.run(remaining)
    case "verify-compile-lock-repro":
      try CoreToolVerification.verifyCompileLockRepro(remaining)
    case "verify-manifest-fixtures":
      try CoreToolVerification.verifyManifestFixtures(remaining)
    default:
      throw MaintenanceError.failure("Unknown maintenance command: \(command)")
    }
  }
}

do {
  try MaintenanceCommand.run(Array(CommandLine.arguments.dropFirst()))
} catch {
  FileHandle.standardError.write(Data("LMD maintenance failed: \(error)\n".utf8))
  exit(EXIT_FAILURE)
}
