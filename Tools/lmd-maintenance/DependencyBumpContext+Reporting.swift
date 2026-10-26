//
//  DependencyBumpContext+Reporting.swift
//  lmd-maintenance
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-10-25.
//  Copyright © 2026, all rights reserved.
//

import Foundation
import SwiftMkCore

private let shortDependencyCommitLength = 7

// MARK: - Dependency bump output

struct DependencyBumpOutputs: Codable {
  let beforeSHA: String
  let afterSHA: String
  let branch: String
  let compareURL: String
  let alreadyCurrent: Bool

  init(beforeSHA: String, afterSHA: String, branch: String, compareURL: String) {
    self.beforeSHA = beforeSHA
    self.afterSHA = afterSHA
    self.branch = branch
    self.compareURL = compareURL
    alreadyCurrent = beforeSHA == afterSHA
  }

  enum CodingKeys: String, CodingKey {
    case beforeSHA = "before_sha"
    case afterSHA = "after_sha"
    case branch = "bump_branch"
    case compareURL = "compare_url"
    case alreadyCurrent = "already_current"
  }

  var text: String {
    """
    before_sha=\(beforeSHA)
    after_sha=\(afterSHA)
    bump_branch=\(branch)
    already_current=\(alreadyCurrent)
    compare_url=\(compareURL)

    """
  }
}

// MARK: - Manual review report

extension DependencyBumpContext {
  func report(_ outputs: DependencyBumpOutputs) throws {
    FileHandle.standardOutput.write(Data(outputs.text.utf8))
    if let path = environment["GITHUB_OUTPUT"], !path.isEmpty {
      try append(outputs.text, to: path)
    }
    let summary = summary(outputs)
    FileHandle.standardOutput.write(Data(summary.utf8))
    if let path = environment["GITHUB_STEP_SUMMARY"], !path.isEmpty {
      try append(summary, to: path)
    }
  }

  func reviewURL(_ branch: String) throws -> String {
    guard let server = environment["GITHUB_SERVER_URL"], !server.isEmpty else {
      throw MaintenanceError.failure("Set GITHUB_SERVER_URL before publishing a dependency bump.")
    }
    guard let name = environment["GITHUB_REPOSITORY"], !name.isEmpty else {
      throw MaintenanceError.failure("Set GITHUB_REPOSITORY before publishing a dependency bump.")
    }
    return "\(server)/\(name)/compare/main...\(branch)?expand=1"
  }

  private func summary(_ outputs: DependencyBumpOutputs) -> String {
    let source = payload.source.rawValue
    if outputs.alreadyCurrent {
      return """
        ### Dependency already matches the tag

        `\(source)` is already at `\(payload.tag)` (`\(outputs.afterSHA.prefix(shortDependencyCommitLength))`).

        """
    }
    return """
      ### Review the dependency update

      Branch `\(outputs.branch)` updates `\(source)` from `\(outputs.beforeSHA)` to `\(outputs.afterSHA)`.

      [Open the pull request](\(outputs.compareURL))

      This command does not open pull requests. A person must review and open the branch.

      """
  }

  private func append(_ text: String, to path: String) throws {
    Output.debug("dependency_bump.report.append path=\(path)")
    let data = Data(text.utf8)
    let url = URL(fileURLWithPath: path)
    if !FileManager.default.fileExists(atPath: path) {
      try data.write(to: url)
      return
    }
    let handle = try FileHandle(forWritingTo: url)
    do {
      try handle.seekToEnd()
      try handle.write(contentsOf: data)
      try handle.close()
    } catch {
      let failure = error
      do { try handle.close() } catch {
        Output.error("dependency_bump.report.close_failed path=\(path) error=\(error)")
      }
      throw failure
    }
  }
}
