//
//  UpstreamSyncTests.swift
//  MaintenanceTests
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-10-25.
//  Copyright © 2026, all rights reserved.
//

import Foundation
import Nimble
import SwiftMkCore
import XCTest

@testable import lmd_maintenance

// MARK: - Real synchronization command regression

final class UpstreamSyncTests: XCTestCase {
  func testCommandsRejectMissingEnvironmentBeforeRepositoryOperations() throws {
    let fixture = try UpstreamSyncTestsFixture()
    addTeardownBlock { [directory = fixture.directory] in
      Output.debug("upstream_sync.fixture.remove path=\(directory.path)")
      try FileManager.default.removeItem(at: directory)
    }
    var environment = fixture.environment
    environment["SYNC_UPSTREAM_URL"] = ""
    let sync = Shell.run(
      fixture.binary.path, ["sync-upstream", fixture.directory.path], environment: environment)
    expect(sync.status) == 1
    expect(sync.combined).to(contain("Set SYNC_UPSTREAM_URL"))
    let pullRequest = Shell.run(
      fixture.binary.path,
      ["create-sync-pull-request", fixture.directory.path],
      environment: environment)
    expect(pullRequest.status) == 1
    expect(pullRequest.combined).to(contain("Set GH_TOKEN"))
  }

  func testSyncPreservesRepairsAndRejectsConflictsBeforePublishing() throws {
    let fixture = try UpstreamSyncTestsFixture()
    addTeardownBlock { [directory = fixture.directory] in
      Output.debug("upstream_sync.fixture.remove path=\(directory.path)")
      try FileManager.default.removeItem(at: directory)
    }
    try fixture.prepare()
    try verifyInitialSync(fixture)
    try verifyRepairsAndMergeOrder(fixture)
    try verifyIdempotence(fixture)
    try verifyConflict(fixture)
  }

  private func verifyInitialSync(_ fixture: UpstreamSyncTestsFixture) throws {
    try fixture.synchronize()
    expect(try fixture.state()) == fixture.firstUpstream
    expect(try fixture.git(fixture.worker, ["show", "HEAD:fork.txt"])) == "fork"
    expect(try fixture.git(fixture.worker, ["show", "HEAD:upstream.txt"])) == "upstream"
    let initialHead = try fixture.git(fixture.worker, ["rev-parse", "HEAD"])
    expect(try fixture.remoteHead()) == initialHead
    let messages = try fixture.git(fixture.worker, ["log", "--format=%B", "origin/main..HEAD"])
    expect(messages.contains("[skip ci]")) == false
    let output = try String(contentsOf: fixture.output, encoding: .utf8)
    let head = try fixture.remoteHead()
    expect(output).to(contain("has_changes=true\nhead_sha=\(head)\n"))
    expect(output).to(contain("upstream_sha=\(fixture.firstUpstream)\n"))
  }

  private func verifyRepairsAndMergeOrder(_ fixture: UpstreamSyncTestsFixture) throws {
    let repair = try fixture.commit(fixture.worker, path: "manual-repair.txt", text: "repair\n")
    try fixture.pushCandidate()
    let mainUpdate = try fixture.commit(fixture.main, path: "main-update.txt", text: "main\n")
    try fixture.git(fixture.main, ["push", "origin", "main"])
    let nextUpstream = try fixture.commit(
      fixture.upstream, path: "upstream-update.txt", text: "upstream update\n")
    try fixture.synchronize()
    for ancestor in [repair, mainUpdate, nextUpstream] {
      try fixture.git(fixture.worker, ["merge-base", "--is-ancestor", ancestor, "HEAD"])
    }
    expect(try fixture.git(fixture.worker, ["rev-parse", "HEAD~1^2"])) == nextUpstream
    expect(try fixture.git(fixture.worker, ["rev-parse", "HEAD~2^2"])) == mainUpdate
    expect(try fixture.git(fixture.worker, ["show", "HEAD:manual-repair.txt"])) == "repair"
    expect(try fixture.state()) == nextUpstream
  }

  private func verifyIdempotence(_ fixture: UpstreamSyncTestsFixture) throws {
    let previous = try fixture.remoteHead()
    try fixture.synchronize()
    expect(try fixture.remoteHead()) == previous
    expect(try fixture.git(fixture.worker, ["rev-parse", "HEAD"])) == previous
  }

  private func verifyConflict(_ fixture: UpstreamSyncTestsFixture) throws {
    let state = try fixture.state()
    let repair = try fixture.commit(fixture.worker, path: "shared.txt", text: "fork repair\n")
    try fixture.pushCandidate()
    try fixture.commit(fixture.upstream, path: "shared.txt", text: "conflicting upstream\n")
    let outputBefore = try Data(contentsOf: fixture.output)
    let failed = fixture.invoke()
    expect(failed.status) == 1
    expect(failed.combined).to(contain("CONFLICT"))
    expect(failed.combined).to(contain("Upstream synchronization failed"))
    expect(try fixture.remoteHead()) == repair
    expect(try fixture.state()) == state
    expect(try fixture.git(fixture.worker, ["ls-files", "--unmerged"]).isEmpty) == false
    expect(try Data(contentsOf: fixture.output)) == outputBefore
  }
}
