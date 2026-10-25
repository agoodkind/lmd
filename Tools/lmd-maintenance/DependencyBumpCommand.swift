//
//  DependencyBumpCommand.swift
//  lmd-maintenance
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-10-25.
//  Copyright © 2026, all rights reserved.
//

import Foundation
import SwiftMkCore

// MARK: - Dependency bump command

enum DependencyBumpCommand {
  static func run(_ arguments: [String]) throws {
    let context = try DependencyBumpContext(arguments)
    try context.report(context.bump())
  }
}

// MARK: - DependencyBumpSource

enum DependencyBumpSource: String, Codable {
  case core = "mlx-swift"
  case library = "mlx-swift-lm"
}

// MARK: - DependencyBumpPayload

struct DependencyBumpPayload {
  let source: DependencyBumpSource
  let tag: String

  init(_ environment: [String: String]) throws {
    guard let name = environment["PAYLOAD_SOURCE_REPO"],
      let selectedSource = DependencyBumpSource(rawValue: name)
    else {
      throw MaintenanceError.failure("Set PAYLOAD_SOURCE_REPO to mlx-swift or mlx-swift-lm.")
    }
    guard let selectedTag = environment["PAYLOAD_NEW_TAG"],
      selectedTag.range(of: "^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$", options: .regularExpression)
        == selectedTag.startIndex..<selectedTag.endIndex
    else {
      throw MaintenanceError.failure(
        "Set PAYLOAD_NEW_TAG to a plain tag name of 1 to 64 characters.")
    }
    source = selectedSource
    tag = selectedTag
  }
}

// MARK: - Submodule and branch operations

struct DependencyBumpContext {
  private static let missingRemoteBranchStatus: Int32 = 2
  let repository: URL
  let payload: DependencyBumpPayload
  let environment = ProcessInfo.processInfo.environment

  init(_ arguments: [String]) throws {
    try requireMaintenanceCondition(
      arguments.count == 1 && !arguments[0].isEmpty, "Usage: bump-dependency REPOSITORY")
    repository = URL(fileURLWithPath: arguments[0]).standardizedFileURL
    payload = try DependencyBumpPayload(environment)
  }

  var submodule: URL { repository.appendingPathComponent(payload.source.rawValue) }

  func bump() throws -> DependencyBumpOutputs {
    try requireCleanInputs()
    let source = payload.source.rawValue
    try git(submodule, ["fetch", "--tags", "origin"])
    let target = "refs/tags/" + payload.tag
    let tagResult = runGit(submodule, ["rev-parse", "-q", "--verify", target + "^{commit}"])
    try requireMaintenanceCondition(
      tagResult.status == 0,
      "Tag \(payload.tag) does not identify a commit in \(source).\n\(tagResult.combined)")
    let before = try git(repository, ["rev-parse", "HEAD:" + source])
    try git(submodule, ["checkout", "--detach", target])
    let after = try git(submodule, ["rev-parse", "HEAD"])
    if before == after {
      return DependencyBumpOutputs(beforeSHA: before, afterSHA: after, branch: "", compareURL: "")
    }
    let branch = "auto-update/\(source)-\(payload.tag)"
    let compareURL = try reviewURL(branch)
    try requireNewBranch(branch)
    try publish(branch)
    return DependencyBumpOutputs(
      beforeSHA: before, afterSHA: after, branch: branch, compareURL: compareURL)
  }

  private func requireCleanInputs() throws {
    try requireMaintenanceCondition(
      git(repository, ["status", "--porcelain"]).isEmpty,
      "Commit or remove working tree changes before preparing a dependency bump.")
    let entry = try git(repository, ["ls-tree", "HEAD", "--", payload.source.rawValue])
    try requireMaintenanceCondition(
      entry.hasPrefix("160000 commit "), "The selected dependency must be a tracked Git submodule.")
    try requireMaintenanceCondition(
      git(submodule, ["status", "--porcelain"]).isEmpty,
      "Commit or remove selected submodule changes before preparing a dependency bump.")
  }

  private func requireNewBranch(_ branch: String) throws {
    let result = runGit(
      repository, ["ls-remote", "--exit-code", "--heads", "origin", "refs/heads/" + branch])
    if result.status == 0 {
      throw MaintenanceError.failure(
        "Branch \(branch) already exists. Review its commits before updating it manually.")
    }
    try requireMaintenanceCondition(
      result.status == Self.missingRemoteBranchStatus,
      "Cannot inspect the existing remote branch. Git exited \(result.status).\n\(result.combined)")
  }

  private func publish(_ branch: String) throws {
    let source = payload.source.rawValue
    try git(repository, ["checkout", "-b", branch])
    try git(repository, ["add", "--", source])
    try requireMaintenanceCondition(
      git(repository, ["diff", "--cached", "--name-only"]) == source,
      "The dependency bump must commit only its selected submodule pointer.")
    try git(
      repository,
      [
        "-c", "user.name=github-actions[bot]",
        "-c", "user.email=41898282+github-actions[bot]@users.noreply.github.com",
        "commit", "-m", "Update \(source) submodule to \(payload.tag)",
      ])
    try git(repository, ["push", "origin", "HEAD:refs/heads/" + branch])
  }

  @discardableResult
  func git(_ directory: URL, _ arguments: [String]) throws -> String {
    let result = runGit(directory, arguments)
    try requireMaintenanceCondition(
      result.status == 0,
      "Dependency bump failed: Git exited \(result.status).\n\(result.combined)")
    return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private func runGit(_ directory: URL, _ arguments: [String]) -> Shell.Result {
    Output.debug("dependency_bump.git directory=\(directory.path)")
    return Shell.run(
      "/usr/bin/env", ["-C", directory.path, "git"] + arguments, environment: environment)
  }
}
