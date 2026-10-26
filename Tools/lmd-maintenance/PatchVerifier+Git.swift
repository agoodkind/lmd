//
//  PatchVerifier+Git.swift
//  lmd-maintenance
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-10-25.
//  Copyright © 2026, all rights reserved.
//

import Foundation
import SwiftMkCore

extension PatchVerifier {

  struct Replay {
    let temporary: URL
    let prefix: [String]
    let environment: [String: String]

    func remove() {
      Output.debug("patches.cleanup_started")
      do {
        try FileManager.default.removeItem(at: temporary)
      } catch {
        Output.error("Cannot remove temporary patch storage: \(error)")
      }
    }
  }

  func makeReplay(repository: URL) throws -> Replay {
    let objectDirectory = try git([
      "-C", repository.path, "rev-parse", "--path-format=absolute", "--git-path", "objects",
    ])
    let temporary = fileManager.temporaryDirectory.appendingPathComponent(
      "lmd-patches-\(UUID().uuidString)")
    try fileManager.createDirectory(at: temporary, withIntermediateDirectories: false)
    let bare = temporary.appendingPathComponent("replay.git")
    _ = try git(["init", "--bare", "--quiet", bare.path])
    return Replay(
      temporary: temporary,
      prefix: ["--git-dir", bare.path],
      environment: [
        "GIT_INDEX_FILE": temporary.appendingPathComponent("index").path,
        "GIT_OBJECT_DIRECTORY": bare.appendingPathComponent("objects").path,
        "GIT_ALTERNATE_OBJECT_DIRECTORIES": objectDirectory,
      ])
  }

  func verifyCommittedFile(_ file: URL, root: URL) throws {
    let resolved = file.resolvingSymlinksInPath()
    try requireMaintenanceCondition(
      resolved.path == file.standardizedFileURL.path && resolved.path.hasPrefix(root.path + "/"),
      "Catalog files must remain inside the selected checkout without symbolic links: \(file.path)."
    )
    let path = String(resolved.path.dropFirst(root.path.count + 1))
    let entry = try git(["-C", root.path, "ls-tree", options.catalogRef, "--", path])
    try requireMaintenanceCondition(
      entry.hasPrefix("100644 blob "),
      "The catalog file must be committed as a regular file: \(path).")
    let recorded = try git(["-C", root.path, "rev-parse", "\(options.catalogRef):\(path)"])
    let actual = try git(["-C", root.path, "hash-object", "--no-filters", "--", resolved.path])
    try requireMaintenanceCondition(
      recorded == actual, "The catalog file differs from --catalog-ref: \(path).")
  }

  func validateReportLocation(catalogRoot: URL) throws {
    Output.debug("patches.report_location_checked")
    let report = options.report.resolvingSymlinksInPath()
    let roots = [catalogRoot] + Array(options.repositories.values)
    for root in roots {
      let resolved = root.resolvingSymlinksInPath()
      try requireMaintenanceCondition(
        report.path != resolved.path && !report.path.hasPrefix(resolved.path + "/"),
        "Write the patch verification report outside source checkouts: \(report.path).")
    }
    try fileManager.createDirectory(
      at: report.deletingLastPathComponent(), withIntermediateDirectories: true)
  }

  func verifyCommit(_ commit: String, repository: URL) throws {
    let resolved = try git(["-C", repository.path, "rev-parse", "--verify", "\(commit)^{commit}"])
    try requireMaintenanceCondition(
      resolved == commit, "The selected commit must exist: \(commit).")
  }

  func rejectInheritedGitOverrides() throws {
    let environment = ProcessInfo.processInfo.environment
    for key in [
      "GIT_DIR", "GIT_WORK_TREE", "GIT_COMMON_DIR", "GIT_INDEX_FILE", "GIT_OBJECT_DIRECTORY",
      "GIT_ALTERNATE_OBJECT_DIRECTORIES",
    ] {
      try requireMaintenanceCondition(
        environment[key] == nil, "Unset \(key) before verifying patch trees.")
    }
    try validateAuthenticationOverrides(environment)
  }

  private func validateAuthenticationOverrides(_ environment: [String: String]) throws {
    Output.debug("patches.validateAuthenticationOverrides_started")
    let configKeys = Set(environment.keys.filter { $0.hasPrefix("GIT_CONFIG") })
    guard let countText = environment["GIT_CONFIG_COUNT"] else {
      try requireMaintenanceCondition(
        configKeys.isEmpty, "Remove unsupported Git configuration overrides.")
      return
    }
    guard let count = Int(countText), count >= 0 else {
      throw MaintenanceError.failure("GIT_CONFIG_COUNT must contain a nonnegative integer.")
    }
    var expected: Set<String> = ["GIT_CONFIG_COUNT"]
    for index in 0..<count {
      let keyVariable = "GIT_CONFIG_KEY_\(index)"
      let valueVariable = "GIT_CONFIG_VALUE_\(index)"
      expected.insert(keyVariable)
      expected.insert(valueVariable)
      guard let key = environment[keyVariable], let value = environment[valueVariable] else {
        throw MaintenanceError.failure("Each Git authentication entry requires a key and value.")
      }
      switch key {
      case "http.https://github.com/.extraheader":
        break
      case "credential.https://github.com.helper":
        try requireMaintenanceCondition(
          value.isEmpty, "The GitHub credential helper override must be empty.")
      default:
        throw MaintenanceError.failure(
          "Only the reviewed GitHub authentication overrides are allowed.")
      }
    }
    try requireMaintenanceCondition(
      configKeys == expected, "Remove unsupported or uncounted Git configuration overrides.")
  }

  func git(_ arguments: [String], environment: [String: String] = [:]) throws -> String {
    try gitResult(arguments, environment: environment).stdout
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }

  func gitResult(
    _ arguments: [String], environment: [String: String] = [:]
  ) throws -> Shell.Result {
    Output.debug("patches.git_command_started")
    var overrides = environment
    overrides["GIT_OPTIONAL_LOCKS"] = "0"
    overrides["GIT_CONFIG_NOSYSTEM"] = "1"
    overrides["GIT_CONFIG_GLOBAL"] = "/dev/null"
    overrides["GIT_NO_REPLACE_OBJECTS"] = "1"
    overrides["GIT_TERMINAL_PROMPT"] = "0"
    let result = Shell.run("git", arguments, environment: overrides)
    try requireMaintenanceCondition(
      result.status == 0,
      "Git patch verification failed (\(result.status)): \(arguments.joined(separator: " "))\n\(result.stderr)"
    )
    return result
  }
}
