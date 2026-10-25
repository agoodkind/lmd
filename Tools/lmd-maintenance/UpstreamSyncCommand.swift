//
//  UpstreamSyncCommand.swift
//  lmd-maintenance
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-10-25.
//  Copyright © 2026, all rights reserved.
//

import Foundation
import SwiftMkCore

// MARK: - Upstream synchronization

enum UpstreamSyncCommand {
  static func run(_ arguments: [String]) throws {
    let context = try UpstreamSyncContext(arguments)
    try context.writeOutputs(context.synchronize())
  }
}

// MARK: - UpstreamSyncOutputs

struct UpstreamSyncOutputs: Codable {
  let hasChanges: Bool
  let headSHA: String
  let upstreamSHA: String

  enum CodingKeys: String, CodingKey {
    case hasChanges = "has_changes"
    case headSHA = "head_sha"
    case upstreamSHA = "upstream_sha"
  }

  var text: String {
    "has_changes=\(hasChanges)\nhead_sha=\(headSHA)\nupstream_sha=\(upstreamSHA)\n"
  }
}

// MARK: - Repository operations

struct UpstreamSyncContext {
  static let candidateBranch = "sync/upstream-latest"
  static let statePath = ".github/upstream-sync-state"
  let repository: URL
  let environment = ProcessInfo.processInfo.environment

  init(_ arguments: [String]) throws {
    try requireMaintenanceCondition(
      arguments.count == 1 && !arguments[0].isEmpty,
      "Usage: sync-upstream REPOSITORY or create-sync-pull-request REPOSITORY")
    repository = URL(fileURLWithPath: arguments[0]).standardizedFileURL
  }

  func synchronize() throws -> UpstreamSyncOutputs {
    let upstream = try requiredEnvironment("SYNC_UPSTREAM_URL")
    try requireMaintenanceCondition(
      git(["status", "--porcelain"]).isEmpty,
      "Commit or remove working tree changes before synchronizing.")
    try git(["fetch", "--no-tags", "origin"])
    let candidate = "refs/remotes/origin/" + Self.candidateBranch
    let previous = try git(["for-each-ref", "--format=%(objectname)", candidate])
    try git(["fetch", "--no-tags", upstream, "main"])
    let upstreamSHA = try git(["rev-parse", "FETCH_HEAD"])
    try git(["switch", "--detach", previous.isEmpty ? "origin/main" : previous])
    try git(["merge", "--no-edit", "-m", "Merge main into upstream candidate", "origin/main"])
    if try readState() != upstreamSHA {
      try mergeUpstream(upstreamSHA)
    }
    let headSHA = try git(["rev-parse", "HEAD"])
    let hasChanges = try git(["rev-list", "--count", "origin/main..HEAD"]) != "0"
    if hasChanges, headSHA != previous {
      try git(["push", "origin", "HEAD:refs/heads/" + Self.candidateBranch])
    }
    return UpstreamSyncOutputs(hasChanges: hasChanges, headSHA: headSHA, upstreamSHA: upstreamSHA)
  }

  private func mergeUpstream(_ revision: String) throws {
    try git([
      "merge", "--no-edit", "--allow-unrelated-histories", "-m",
      "Merge upstream main into sync candidate", revision,
    ])
    let state = repository.appendingPathComponent(Self.statePath)
    Output.debug("upstream_sync.state.write path=\(state.path)")
    try FileManager.default.createDirectory(
      at: state.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data((revision + "\n").utf8).write(to: state)
    try git(["add", Self.statePath])
    try git(["commit", "-m", "Record upstream main at \(revision)"])
  }

  @discardableResult
  func git(_ arguments: [String]) throws -> String {
    try command("git", arguments).trimmingCharacters(in: .whitespacesAndNewlines)
  }

  @discardableResult
  func command(_ executable: String, _ arguments: [String]) throws -> String {
    Output.debug("upstream_sync.command executable=\(executable) repository=\(repository.path)")
    let result = Shell.run(
      "/usr/bin/env", ["-C", repository.path, executable] + arguments, environment: environment)
    try requireMaintenanceCondition(
      result.status == 0,
      "Upstream synchronization failed: \(executable) exited \(result.status).\n\(result.combined)")
    return result.stdout
  }

  func requiredEnvironment(_ key: String) throws -> String {
    guard let value = environment[key], !value.isEmpty else {
      throw MaintenanceError.failure("Set \(key) before running upstream synchronization.")
    }
    return value
  }

  func readState() throws -> String? {
    let state = repository.appendingPathComponent(Self.statePath)
    Output.debug("upstream_sync.state.read path=\(state.path)")
    do {
      return try String(contentsOf: state, encoding: .utf8)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
      return nil
    }
  }

  func writeOutputs(_ outputs: UpstreamSyncOutputs) throws {
    let data = Data(outputs.text.utf8)
    FileHandle.standardOutput.write(data)
    guard let path = environment["GITHUB_OUTPUT"], !path.isEmpty else { return }
    Output.debug("upstream_sync.outputs.append path=\(path)")
    if !FileManager.default.fileExists(atPath: path) {
      try data.write(to: URL(fileURLWithPath: path))
      return
    }
    let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
    do {
      try handle.seekToEnd()
      try handle.write(contentsOf: data)
      try handle.close()
    } catch {
      let failure = error
      do { try handle.close() } catch {
        Output.error("upstream_sync.outputs.close_failed path=\(path) error=\(error)")
      }
      throw failure
    }
  }
}
