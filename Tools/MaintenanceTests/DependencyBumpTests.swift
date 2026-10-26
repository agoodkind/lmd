//
//  DependencyBumpTests.swift
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

// MARK: - Real dependency bump command regression

final class DependencyBumpTests: XCTestCase {
  func testReleasedTagsUpdateOnlyTheirGitlinksAndCurrentTagsDoNotPush() throws {
    for source in ["mlx-swift", "mlx-swift-lm"] {
      let fixture = try fixture(source)
      try fixture.prepare()
      let release = try fixture.release()
      let result = fixture.invoke()
      try requireMaintenanceCondition(result.status == 0, result.combined)
      expect(try fixture.git(fixture.worker, ["rev-parse", "HEAD:" + source])) == release
      expect(try fixture.git(fixture.worker, ["rev-parse", "HEAD^"])) == fixture.original
      expect(try fixture.git(fixture.worker, ["diff", "--name-only", "HEAD^", "HEAD"])) == source
      try fixture.git(fixture.seed, ["merge-base", "--is-ancestor", fixture.first, release])
      let updated = try fixture.git(fixture.worker, ["rev-parse", "HEAD"])
      expect(try fixture.remoteHead()) == updated
      expect(try fixture.git(fixture.origin, ["rev-parse", "main"])) == fixture.original
      expect(result.stdout).to(contain("before_sha=\(fixture.first)\nafter_sha=\(release)\n"))
      expect(result.stdout).to(contain("bump_branch=\(fixture.branch)\nalready_current=false\n"))
      let summary = try String(contentsOf: fixture.summary, encoding: .utf8)
      expect(summary).to(contain("/compare/main...\(fixture.branch)?expand=1"))
      let remoteRefs = try fixture.git(fixture.origin, ["show-ref"])
      let current = fixture.invoke()
      try requireMaintenanceCondition(current.status == 0, current.combined)
      expect(current.stdout).to(contain("already_current=true"))
      expect(try fixture.git(fixture.worker, ["rev-parse", "HEAD"])) == updated
      expect(try fixture.git(fixture.origin, ["show-ref"])) == remoteRefs
    }
  }

  func testExistingBranchesAndRemoteErrorsPreventPublishing() throws {
    let existing = try fixture("mlx-swift")
    try existing.prepare()
    try existing.release()
    try existing.git(
      existing.origin, ["update-ref", "refs/heads/" + existing.branch, existing.original])
    let rejected = existing.invoke()
    expect(rejected.status) == 1
    expect(rejected.combined).to(contain("already exists"))
    expect(try existing.remoteHead()) == existing.original
    expect(try existing.git(existing.worker, ["rev-parse", "HEAD"])) == existing.original

    let unavailable = try fixture("mlx-swift-lm")
    try unavailable.prepare()
    try unavailable.release()
    try unavailable.git(
      unavailable.worker,
      [
        "remote", "set-url", "origin",
        unavailable.directory.appendingPathComponent("missing.git").path,
      ])
    let failed = unavailable.invoke()
    expect(failed.status) == 1
    expect(failed.combined).to(contain("Cannot inspect the existing remote branch"))
    expect(try unavailable.git(unavailable.origin, ["show-ref", "--heads"]))
      == "\(unavailable.original) refs/heads/main"
    expect(try unavailable.git(unavailable.worker, ["rev-parse", "HEAD"])) == unavailable.original
  }

  func testInvalidPayloadsAndMissingTagsFailWithoutPublishing() throws {
    let fixture = try fixture("mlx-swift")
    for values in [
      ["PAYLOAD_SOURCE_REPO": ""], ["PAYLOAD_SOURCE_REPO": "other"],
      ["PAYLOAD_NEW_TAG": ""], ["PAYLOAD_NEW_TAG": "v2;unexpected"],
      ["PAYLOAD_NEW_TAG": "v2\n"],
    ] {
      let rejected = fixture.invoke(overrides: values)
      expect(rejected.status) == 1
      expect(rejected.combined).to(contain("Set PAYLOAD_"))
    }
    try fixture.prepare()
    let missing = fixture.invoke(overrides: ["PAYLOAD_NEW_TAG": "missing-tag"])
    expect(missing.status) == 1
    expect(missing.combined).to(contain("does not identify a commit"))
    expect(try fixture.git(fixture.worker, ["rev-parse", "HEAD"])) == fixture.original
    expect(try fixture.git(fixture.origin, ["show-ref", "--heads"]))
      == "\(fixture.original) refs/heads/main"
  }

  private func fixture(_ source: String) throws -> DependencyBumpTestsFixture {
    let fixture = try DependencyBumpTestsFixture(source: source)
    addTeardownBlock { [directory = fixture.directory] in
      Output.debug("dependency_bump.fixture.remove path=\(directory.path)")
      try FileManager.default.removeItem(at: directory)
    }
    return fixture
  }
}
