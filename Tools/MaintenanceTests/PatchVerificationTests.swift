//
//  PatchVerificationTests.swift
//  LMDMaintenanceTests
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-10-25.
//  Copyright © 2026, all rights reserved.
//

import Foundation
import Nimble
import XCTest

@testable import lmd_maintenance

final class PatchVerificationTests: XCTestCase {
  func testReplayPreservesSourceWorktreesIndexesRefsAndObjects() throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let before = try fixture.snapshots()
    try fixture.verify(fixture.arguments())
    let report = try JSONDecoder().decode(
      PatchVerifier.Report.self,
      from: Data(contentsOf: fixture.report))
    expect(report.sources.count) == 3
    expect(report.sources.map(\.replayedTree)) == fixture.sources.map(\.expectedTree)
    expect(report.sources.map(\.candidateTree)) == fixture.sources.map(\.expectedTree)
    expect(try fixture.snapshots()) == before
  }

  func testMissingPatchFails() throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let patch = fixture.catalogDirectory.appendingPathComponent(fixture.sources[0].patches[0].path)
    try FileManager.default.removeItem(at: patch)
    try fixture.commitCatalog()
    expect { try fixture.verify(fixture.arguments()) }.to(throwError())
  }

  func testReorderedPatchSeriesFails() throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let source = fixture.sources[0]
    fixture.sources[0] = fixture.replacing(
      source,
      patches: Array(source.patches.reversed()))
    try fixture.saveCatalog()
    expect { try fixture.verify(fixture.arguments()) }.to(throwError())
  }

  func testCommittedPatchTamperingFailsChecksumValidation() throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let patch = fixture.catalogDirectory.appendingPathComponent(fixture.sources[0].patches[0].path)
    var data = try Data(contentsOf: patch)
    data.append(Data("\nchanged patch\n".utf8))
    try data.write(to: patch)
    try fixture.commitCatalog()
    expect { try fixture.verify(fixture.arguments()) }.to(
      throwError { error in
        expect(String(describing: error).contains("checksum mismatch")) == true
      })
  }

  func testCandidateCannotRemoveCatalogFeature() throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let repository = fixture.repositories[0]
    try Data("upstream\n".utf8).write(to: repository.appendingPathComponent("Feature.swift"))
    let candidate = try fixture.commit(repository)
    expect {
      try fixture.verify(fixture.arguments(coreRef: candidate))
    }.to(throwError())
  }

  func testOnlyTheExistingCallerSHAPairCanChange() throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let repository = fixture.repositories[0]
    let workflow = repository.appendingPathComponent(fixture.workflowPaths[0])
    let original = try String(
      contentsOf: workflow,
      encoding: .utf8)
    let repinned = original.replacingOccurrences(
      of: fixture.oldWorkflowRef,
      with: fixture.catalogRef)
    try Data(repinned.utf8).write(to: workflow)
    let candidate = try fixture.commit(repository)
    try fixture.verify(fixture.arguments(coreRef: candidate))
    let report = try JSONDecoder().decode(
      PatchVerifier.Report.self,
      from: Data(contentsOf: fixture.report))
    expect(report.sources[0].normalizedMetadataPaths) == [fixture.workflowPaths[0]]
    try Data((repinned + "# unexpected workflow edit\n").utf8).write(to: workflow)
    let changedCandidate = try fixture.commit(repository)
    expect {
      try fixture.verify(fixture.arguments(coreRef: changedCandidate))
    }.to(throwError())
    let half = original.replacingOccurrences(
      of: "@\(fixture.oldWorkflowRef)",
      with: "@\(fixture.catalogRef)")
    try Data(half.utf8).write(to: workflow)
    let halfCandidate = try fixture.commit(repository)
    expect {
      try fixture.verify(fixture.arguments(coreRef: halfCandidate))
    }.to(throwError())
  }

  func testNamedProfileRequiresItsExactCommitAndUntamperedDelta() throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let source = fixture.sources[0]
    let profile = try XCTUnwrap(source.profiles.first)
    try fixture.verify(
      fixture.arguments(
        coreRef: profile.commit,
        coreProfile: profile.name))
    let report = try JSONDecoder().decode(
      PatchVerifier.Report.self,
      from: Data(contentsOf: fixture.report))
    expect(report.sources[0].replayedTree) == source.expectedTree
    expect(report.sources[0].profilePatch?.tree) == profile.patch.expectedTree
    expect {
      try fixture.verify(fixture.arguments(coreRef: profile.commit))
    }.to(throwError())
    expect {
      try fixture.verify(fixture.arguments(coreProfile: profile.name))
    }.to(throwError())
    expect {
      try fixture.verify(fixture.arguments(coreProfile: "unlisted-profile"))
    }.to(throwError())
    let patch = fixture.catalogDirectory.appendingPathComponent(profile.patch.path)
    var data = try Data(contentsOf: patch)
    data.append(Data("\nchanged profile\n".utf8))
    try data.write(to: patch)
    try fixture.commitCatalog()
    expect {
      try fixture.verify(
        fixture.arguments(
          coreRef: profile.commit,
          coreProfile: profile.name))
    }.to(
      throwError { error in
        expect(String(describing: error).contains("checksum mismatch")) == true
      })
  }

  func testCatalogWorktreeChangesRequireAnExplicitCommit() throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    var data = try Data(contentsOf: fixture.catalog)
    data.append(Data("\n".utf8))
    try data.write(to: fixture.catalog)
    expect { try fixture.verify(fixture.arguments()) }.to(
      throwError { error in
        expect(String(describing: error).contains("differs from --catalog-ref")) == true
      })
  }

  func testEmptyOptionalProfilesSelectCanonicalComparison() throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let arguments =
      fixture.arguments() + [
        "--core-profile", "", "--library-profile", "", "--swiftlm-profile", "",
      ]
    try fixture.verify(arguments)
    expect {
      try fixture.verify(fixture.arguments(coreProfile: " "))
    }.to(throwError())
  }

  func testPermitsOnlyReviewedGitHubAuthenticationOverrides() throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    var environment = [
      "GIT_CONFIG_COUNT": "3",
      "GIT_CONFIG_KEY_0": "http.https://github.com/.extraheader",
      "GIT_CONFIG_VALUE_0": "",
      "GIT_CONFIG_KEY_1": "http.https://github.com/.extraheader",
      "GIT_CONFIG_VALUE_1": "",
      "GIT_CONFIG_KEY_2": "credential.https://github.com.helper",
      "GIT_CONFIG_VALUE_2": "",
    ]
    let accepted = try fixture.verificationResult(
      fixture.arguments(),
      environment: environment)
    expect(accepted.status) == 0
    environment["GIT_CONFIG_KEY_1"] = "url.https://example.invalid/.insteadOf"
    environment["GIT_CONFIG_VALUE_1"] = "https://github.com/"
    let rejected = try fixture.verificationResult(
      fixture.arguments(),
      environment: environment)
    expect(rejected.status) != 0
    expect(rejected.stderr).to(contain("Only the reviewed GitHub authentication overrides"))
  }

}
