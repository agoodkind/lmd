//
//  DependencyBumpTestsFixture.swift
//  MaintenanceTests
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-10-25.
//  Copyright © 2026, all rights reserved.
//

import Foundation
import SwiftMkCore
import XCTest

@testable import lmd_maintenance

// MARK: - Real tagged submodule and bare origins

final class DependencyBumpTestsFixture {
  let directory: URL
  let origin: URL
  let dependencyOrigin: URL
  let seed: URL
  let umbrella: URL
  let worker: URL
  let summary: URL
  let source: String
  let binary: URL
  var environment = ProcessInfo.processInfo.environment
  var original = ""
  var first = ""
  var branch: String { "auto-update/" + source + "-v2" }

  init(source: String) throws {
    self.source = source
    directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "lmd-dependency-bump-" + UUID().uuidString)
    origin = directory.appendingPathComponent("origin.git")
    dependencyOrigin = directory.appendingPathComponent("dependency.git")
    seed = directory.appendingPathComponent("seed")
    umbrella = directory.appendingPathComponent("umbrella")
    worker = directory.appendingPathComponent("worker")
    summary = directory.appendingPathComponent("summary.md")
    binary = try MaintenanceTestExecutable.locate(for: DependencyBumpTests.self)
    environment["GIT_CONFIG_NOSYSTEM"] = "1"
    environment["GIT_CONFIG_GLOBAL"] = "/dev/null"
    environment["GIT_CONFIG_COUNT"] = "1"
    environment["GIT_CONFIG_KEY_0"] = "protocol.file.allow"
    environment["GIT_CONFIG_VALUE_0"] = "always"
    environment["GIT_TERMINAL_PROMPT"] = "0"
    environment["PAYLOAD_SOURCE_REPO"] = source
    environment["PAYLOAD_NEW_TAG"] = "v2"
    environment["GITHUB_SERVER_URL"] = "https://github.com"
    environment["GITHUB_REPOSITORY"] = "agoodkind/SwiftLM"
    environment["GITHUB_OUTPUT"] = directory.appendingPathComponent("outputs.txt").path
    environment["GITHUB_STEP_SUMMARY"] = summary.path
    Output.debug("dependency_bump.fixture.create path=\(directory.path)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
  }

  func prepare() throws {
    try initialize(origin, bare: true)
    try initialize(dependencyOrigin, bare: true)
    try initialize(seed)
    first = try commit(seed, "Value.txt", "first\n")
    try git(seed, ["remote", "add", "origin", dependencyOrigin.path])
    try git(seed, ["push", "origin", "main"])
    try initialize(umbrella)
    try commit(umbrella, "README.md", "umbrella\n")
    try git(umbrella, ["submodule", "add", dependencyOrigin.path, source])
    try git(umbrella, ["add", ".gitmodules", source])
    try git(umbrella, ["commit", "-m", "Add the real dependency submodule"])
    original = try git(umbrella, ["rev-parse", "HEAD"])
    try git(umbrella, ["remote", "add", "origin", origin.path])
    try git(umbrella, ["push", "origin", "main"])
    try git(directory, ["clone", "--recurse-submodules", origin.path, worker.path])
  }

  @discardableResult
  func release() throws -> String {
    let revision = try commit(seed, "Value.txt", "released\n")
    try git(seed, ["tag", "--annotate", "--message", "Release v2", "v2", revision])
    try git(seed, ["push", "origin", "main", "refs/tags/v2"])
    return revision
  }

  private func initialize(_ path: URL, bare: Bool = false) throws {
    Output.debug("dependency_bump.fixture.repository.create path=\(path.path)")
    try FileManager.default.createDirectory(at: path, withIntermediateDirectories: false)
    var arguments = ["init", "--initial-branch=main"]
    if bare { arguments.append("--bare") }
    try git(path, arguments)
    if !bare {
      try git(path, ["config", "user.name", "Dependency Test"])
      try git(path, ["config", "user.email", "dependency-test@example.invalid"])
    }
  }

  @discardableResult
  func commit(_ path: URL, _ name: String, _ value: String) throws -> String {
    let file = path.appendingPathComponent(name)
    Output.debug("dependency_bump.fixture.write path=\(file.path)")
    try Data(value.utf8).write(to: file)
    try git(path, ["add", name])
    try git(path, ["commit", "-m", "Update \(name)\n\nCo-authored-by: Codex <noreply@openai.com>"])
    return try git(path, ["rev-parse", "HEAD"])
  }

  @discardableResult
  func git(_ path: URL, _ arguments: [String]) throws -> String {
    Output.debug("dependency_bump.fixture.git directory=\(path.path)")
    let result = Shell.run(
      "/usr/bin/env", ["-C", path.path, "git"] + arguments, environment: environment)
    try requireMaintenanceCondition(result.status == 0, result.combined)
    return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  func invoke(overrides: [String: String] = [:]) -> Shell.Result {
    Output.debug("dependency_bump.fixture.invoke")
    return Shell.run(
      binary.path,
      ["bump-dependency", worker.path],
      environment: environment.merging(overrides) { _, replacement in replacement })
  }

  func remoteHead() throws -> String {
    try git(origin, ["rev-parse", "refs/heads/" + branch])
  }
}
