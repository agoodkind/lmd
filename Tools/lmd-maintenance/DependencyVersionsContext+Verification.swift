//
//  DependencyVersionsContext+Verification.swift
//  lmd-maintenance
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-10-25.
//  Copyright © 2026, all rights reserved.
//

import Foundation
import SwiftMkCore

// MARK: - Source and lock verification

extension DependencyVersionsContext {
  func verify() throws {
    try snapshotLocks()
    var state = try readState()
    try verifySources(state)
    let expected = ["mlx-swift": try ref("CORE_REF"), "mlx-swift-lm": state.effectiveLibrary]
    state.resolved = try verifyLocks(expected: expected)
    try verifySwiftLM(expected: expected, state: &state)
    try verifyRootSource()
    try writeJSON(state, to: stateURL)
    Output.log("Verified exact core, effective library, SwiftLM, and LMD versions")
  }

  private func verifySources(_ state: DependencyVersionsState) throws {
    let commit = proof.appendingPathComponent("library-commit-object.txt")
    try requireMaintenanceCondition(
      try git(library, ["hash-object", "-t", "commit", commit.path]) == state.effectiveLibrary
        && maintenanceSHA256(Data(contentsOf: commit)) == state.libraryCommitSha256,
      "Archived library commit object changed")
    try requireMaintenanceCondition(state.requested == refs, "DependencyVersions inputs changed")
    try requireMaintenanceCondition(state.libraryBase == ref("LIBRARY_REF"), "Library base changed")
    try requireMaintenanceCondition(
      state.newCoreRequirement == ref("CORE_REF"), "Core requirement changed")
    try requireMaintenanceCondition(
      maintenanceSHA256(try Data(contentsOf: proof.appendingPathComponent("library-overlay.patch")))
        == state.libraryOverlaySha256,
      "Library overlay archive changed")
    for (directory, revision) in [
      (root, try ref("LMD_REF")), (core, try ref("CORE_REF")),
      (library, state.effectiveLibrary),
    ] {
      try requireMaintenanceCondition(
        try git(directory, ["rev-parse", "HEAD"]) == revision,
        "Source checkout changed: \(directory.path)")
    }
    try requireMaintenanceCondition(
      try git(core, ["status", "--porcelain"]).isEmpty,
      "The dedicated core checkout must remain clean")
    try requireMaintenanceCondition(
      try git(library, ["status", "--porcelain"]).isEmpty,
      "The effective library checkout must be clean")
    try git(
      library,
      [
        "diff", "--exit-code", try ref("LIBRARY_REF"), state.effectiveLibrary, "--", ".",
        ":!Package.swift",
      ])
    try requireMaintenanceCondition(
      try git(library, ["rev-parse", "HEAD^{tree}"]) == state.libraryOverlayTree,
      "Effective library tree changed")
  }

  private func verifyLocks(expected: [String: String]) throws -> [DependencyVersionsResolvedPackage]
  {
    var resolved: [DependencyVersionsResolvedPackage] = []
    for packagePath in packagePaths {
      let directory = root.appendingPathComponent(packagePath)
      let lockURL = directory.appendingPathComponent("Package.resolved")
      let lock = try DependencyVersionsLock(lockURL)
      let baseline = try DependencyVersionsLock(
        proof.appendingPathComponent("baseline-" + lockName(packagePath)))
      try requireMaintenanceCondition(
        try lock.otherPins(excluding: identities) == baseline.otherPins(excluding: identities),
        "Resolver changed dependencies outside the requested MLX versions: \(lockURL.path)")
      for identity in identities {
        try requireMaintenanceCondition(
          try lock.revision(identity) == expected[identity],
          "Resolved revision mismatch: \(lockURL.path) \(identity)")
        let checkout = directory.appendingPathComponent(".build/checkouts/" + identity)
        try requireMaintenanceCondition(
          try git(checkout, ["rev-parse", "HEAD"]) == expected[identity],
          "Resolved checkout mismatch: \(checkout.path)")
        try requireMaintenanceCondition(
          try git(checkout, ["status", "--porcelain", "--untracked-files=no"]).isEmpty,
          "Resolved source package changed: \(checkout.path)")
      }
      resolved.append(
        DependencyVersionsResolvedPackage(
          package: packagePath.isEmpty ? "." : packagePath,
          sha256: maintenanceSHA256(try Data(contentsOf: lockURL)),
          revisions: expected))
    }
    return resolved
  }

  private func verifySwiftLM(expected: [String: String], state: inout DependencyVersionsState)
    throws
  {
    let swiftLM = root.appendingPathComponent("SwiftLM")
    try requireMaintenanceCondition(
      try git(swiftLM, ["rev-parse", "HEAD"]) == ref("SWIFTLM_REF"), "SwiftLM source commit changed"
    )
    for path in try git(swiftLM, ["diff", "--name-only", "HEAD"]).split(separator: "\n") {
      try requireMaintenanceCondition(
        (identities + ["Package.resolved"]).contains(String(path)),
        "Unexpected tracked SwiftLM source change: \(path)")
    }
    let swiftLMLock = swiftLM.appendingPathComponent("Package.resolved")
    let baselineSwiftLM = proof.appendingPathComponent("baseline-swiftlm-Package.resolved")
    try requireMaintenanceCondition(
      try DependencyVersionsLock(swiftLMLock).otherPins(excluding: identities)
        == DependencyVersionsLock(baselineSwiftLM).otherPins(excluding: identities),
      "SwiftLM resolver changed dependencies outside the requested MLX versions")
    state.swiftlmLockSha256 = maintenanceSHA256(try Data(contentsOf: swiftLMLock))
    try gitArchive(
      swiftLM,
      ["diff", "--binary", "--full-index", "HEAD"],
      destination: proof.appendingPathComponent("swiftlm-versions.patch"))
    for identity in identities {
      let checkout = swiftLM.appendingPathComponent(identity)
      try requireMaintenanceCondition(
        try git(checkout, ["rev-parse", "HEAD"]) == expected[identity],
        "Nested SwiftLM checkout mismatch: \(identity)")
      try requireMaintenanceCondition(
        try git(checkout, ["status", "--porcelain", "--untracked-files=no"]).isEmpty,
        "Tracked nested SwiftLM source changed: \(identity)")
    }
  }

  private func verifyRootSource() throws {
    let allowed = Set([
      "Package.swift", "Tuist/Package.swift", "Package.resolved", "Tools/Package.resolved",
      "Tuist/Package.resolved", "SwiftLM",
    ])
    for path in try git(root, ["diff", "--name-only", "HEAD"]).split(separator: "\n") {
      try requireMaintenanceCondition(
        allowed.contains(String(path)), "Unexpected LMD source change: \(path)")
    }
    try gitArchive(
      root,
      ["diff", "--binary", "--full-index", "HEAD"],
      destination: proof.appendingPathComponent("lmd-versions.patch"))
  }
}
