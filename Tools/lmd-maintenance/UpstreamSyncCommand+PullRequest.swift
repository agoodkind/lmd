//
//  UpstreamSyncCommand+PullRequest.swift
//  lmd-maintenance
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-10-25.
//  Copyright © 2026, all rights reserved.
//

import Foundation
import SwiftMkCore

// MARK: - Pull request command

extension UpstreamSyncCommand {
  static func createPullRequest(_ arguments: [String]) throws {
    try UpstreamSyncContext(arguments).updatePullRequest()
  }
}

// MARK: - UpstreamSyncPullRequest

private struct UpstreamSyncPullRequest: Decodable {
  let number: Int
}

// MARK: - GitHub operations

extension UpstreamSyncContext {
  func updatePullRequest() throws {
    _ = try requiredEnvironment("GH_TOKEN")
    let githubRepository = try requiredEnvironment("GITHUB_REPOSITORY")
    let listed = try command(
      "gh",
      [
        "pr", "list", "--repo", githubRepository, "--base", "main", "--head", Self.candidateBranch,
        "--state", "open", "--json", "number",
      ])
    let pullRequests = try JSONDecoder().decode(
      [UpstreamSyncPullRequest].self, from: Data(listed.utf8))
    try requireMaintenanceCondition(
      pullRequests.count <= 1,
      "Resolve duplicate open pull requests for \(Self.candidateBranch).")
    guard let revision = try readState(), !revision.isEmpty else {
      throw MaintenanceError.failure("Synchronize upstream before creating its pull request.")
    }
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "lmd-upstream-pr-" + UUID().uuidString)
    Output.debug("upstream_sync.pull_request_body.create path=\(directory.path)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    do {
      try writePullRequest(
        pullRequests.first,
        repository: githubRepository,
        revision: revision,
        directory: directory)
    } catch {
      let failure = error
      do { try removePullRequestDirectory(directory) } catch {
        Output.error("upstream_sync.pull_request_body.cleanup_failed error=\(error)")
      }
      throw failure
    }
    try removePullRequestDirectory(directory)
  }

  private func writePullRequest(
    _ existing: UpstreamSyncPullRequest?,
    repository githubRepository: String,
    revision: String,
    directory: URL
  ) throws {
    let isCore = githubRepository == "agoodkind/mlx-swift"
    let title = isCore ? "Sync Apple mlx-swift updates" : "Sync upstream updates"
    let prefix = isCore ? "Merge Apple mlx-swift main at" : "Merge upstream main at"
    let body = """
      \(prefix) \(revision).

      The candidate preserves existing repair commits and merges current main before upstream. \
      Conflicts stop synchronization. Review the diff and require successful build and integration checks.
      """
    let path = directory.appendingPathComponent("body.md")
    Output.debug("upstream_sync.pull_request_body.write path=\(path.path)")
    try Data(body.utf8).write(to: path)
    var arguments = ["pr"]
    if let existing {
      arguments += ["edit", String(existing.number), "--repo", githubRepository]
    } else {
      arguments += [
        "create", "--repo", githubRepository, "--base", "main", "--head", Self.candidateBranch,
      ]
    }
    arguments += ["--title", title, "--body-file", path.path]
    try command("gh", arguments)
  }

  private func removePullRequestDirectory(_ directory: URL) throws {
    Output.debug("upstream_sync.pull_request_body.remove path=\(directory.path)")
    try FileManager.default.removeItem(at: directory)
  }
}
