//
//  UpstreamSyncTestsFixture.swift
//  MaintenanceTests
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-10-25.
//  Copyright © 2026, all rights reserved.
//

import Foundation
import SwiftMkCore
import XCTest

@testable import lmd_maintenance

// MARK: - Bare origin and independent upstream fixture

final class UpstreamSyncTestsFixture {
  let directory: URL
  let origin: URL
  let upstream: URL
  let main: URL
  let worker: URL
  let output: URL
  let binary: URL
  var environment = ProcessInfo.processInfo.environment
  var firstUpstream = ""

  init() throws {
    directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "lmd-upstream-sync-" + UUID().uuidString)
    origin = directory.appendingPathComponent("origin.git")
    upstream = directory.appendingPathComponent("upstream")
    main = directory.appendingPathComponent("main")
    worker = directory.appendingPathComponent("worker")
    output = directory.appendingPathComponent("outputs.txt")
    binary = Bundle(for: UpstreamSyncTests.self).bundleURL.deletingLastPathComponent()
      .appendingPathComponent("lmd-maintenance")
    environment["GIT_CONFIG_NOSYSTEM"] = "1"
    environment["GIT_CONFIG_GLOBAL"] = "/dev/null"
    environment["GIT_CONFIG_COUNT"] = "0"
    environment["GIT_TERMINAL_PROMPT"] = "0"
    environment["SYNC_UPSTREAM_URL"] = upstream.path
    environment["GITHUB_OUTPUT"] = output.path
    environment["GH_TOKEN"] = ""
    Output.debug("upstream_sync.fixture.create path=\(directory.path)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
  }

  func prepare() throws {
    try initialize(origin, bare: true)
    try initialize(upstream)
    try initialize(main)
    try commit(main, path: "fork.txt", text: "fork\n")
    try commit(main, path: "shared.txt", text: "original\n")
    try git(main, ["remote", "add", "origin", origin.path])
    try git(main, ["push", "origin", "main"])
    try commit(upstream, path: "upstream.txt", text: "upstream\n")
    firstUpstream = try commit(upstream, path: "shared.txt", text: "original\n")
    try git(directory, ["clone", origin.path, worker.path])
    try configureAuthor(worker)
  }

  private func initialize(_ path: URL, bare: Bool = false) throws {
    Output.debug("upstream_sync.fixture.repository.create path=\(path.path)")
    try FileManager.default.createDirectory(at: path, withIntermediateDirectories: false)
    var arguments = ["init", "--initial-branch=main"]
    if bare { arguments.append("--bare") }
    try git(path, arguments)
    if !bare { try configureAuthor(path) }
  }

  private func configureAuthor(_ path: URL) throws {
    try git(path, ["config", "user.name", "Sync Test"])
    try git(path, ["config", "user.email", "sync-test@example.invalid"])
  }

  @discardableResult
  func commit(_ path: URL, path name: String, text: String) throws -> String {
    let file = path.appendingPathComponent(name)
    Output.debug("upstream_sync.fixture.write path=\(file.path)")
    try Data(text.utf8).write(to: file)
    try git(path, ["add", name])
    try git(
      path,
      [
        "commit", "-m", "Update \(name)\n\nCo-authored-by: Codex <noreply@openai.com>",
      ])
    return try git(path, ["rev-parse", "HEAD"])
  }

  @discardableResult
  func git(_ directory: URL, _ arguments: [String]) throws -> String {
    Output.debug("upstream_sync.fixture.git directory=\(directory.path)")
    let result = Shell.run(
      "/usr/bin/env", ["-C", directory.path, "git"] + arguments, environment: environment)
    try requireMaintenanceCondition(result.status == 0, result.combined)
    return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  func invoke() -> Shell.Result {
    Output.debug("upstream_sync.fixture.invoke")
    return Shell.run(binary.path, ["sync-upstream", worker.path], environment: environment)
  }

  func synchronize() throws {
    Output.debug("upstream_sync.fixture.invoke")
    let result = invoke()
    try requireMaintenanceCondition(result.status == 0, result.combined)
  }

  func pushCandidate() throws {
    try git(worker, ["push", "origin", "HEAD:refs/heads/" + UpstreamSyncContext.candidateBranch])
  }

  func remoteHead() throws -> String {
    try git(origin, ["rev-parse", "refs/heads/" + UpstreamSyncContext.candidateBranch])
  }

  func state() throws -> String {
    let path = worker.appendingPathComponent(UpstreamSyncContext.statePath)
    Output.debug("upstream_sync.fixture.state.read path=\(path.path)")
    return try String(contentsOf: path, encoding: .utf8)
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }
}
