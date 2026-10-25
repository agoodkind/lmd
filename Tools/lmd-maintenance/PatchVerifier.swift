//
//  PatchVerifier.swift
//  lmd-maintenance
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-10-25.
//  Copyright © 2026, all rights reserved.
//

import Foundation
import SwiftMkCore

struct PatchVerifier {
  struct Report: Codable {
    let catalogRef: String
    let catalogSHA256: String
    let sources: [SourceReport]
  }

  struct SourceReport: Codable {
    let repository: String
    let upstreamCommit: String
    let targetCommit: String
    let candidateCommit: String
    let replayedTree: String
    let candidateTree: String
    let normalizedMetadataPaths: [String]
    let profile: String?
    let profilePatch: PatchReport?
    let patches: [PatchReport]
  }

  struct PatchReport: Codable {
    let path: String
    let sha256: String
    let tree: String
    let warnings: String
  }

  let options: PatchVerificationCommand.Options
  let fileManager = FileManager.default
  static let jobIndentWidth = 2

  func verify() throws -> Report {
    try rejectInheritedGitOverrides()
    let catalogDirectory = options.catalog.deletingLastPathComponent()
    let catalogRoot = URL(
      fileURLWithPath: try git(
        ["-C", catalogDirectory.path, "rev-parse", "--show-toplevel"])
    ).resolvingSymlinksInPath()
    try verifyCommit(
      options.catalogRef,
      repository: catalogRoot)
    try verifyCommittedFile(
      options.catalog,
      root: catalogRoot)
    let catalogData = try Data(contentsOf: options.catalog)
    let catalog = try JSONDecoder().decode(
      PatchCatalog.self,
      from: catalogData)
    try catalog.validate()
    try validateReportLocation(catalogRoot: catalogRoot)
    var results: [SourceReport] = []
    for source in catalog.sources {
      guard let repository = options.repositories[source.repository],
        let candidate = options.candidates[source.repository]
      else {
        throw MaintenanceError.failure("Missing selected repository: \(source.repository).")
      }
      for patch in source.patches + source.profiles.map(\.patch) {
        let patchURL = catalogDirectory.appendingPathComponent(patch.path)
        try verifyCommittedFile(
          patchURL,
          root: catalogRoot)
        let data = try Data(contentsOf: patchURL)
        try requireMaintenanceCondition(
          maintenanceSHA256(data) == patch.sha256, "Patch checksum mismatch: \(patch.path).")
      }
      results.append(
        try verifySource(
          source,
          repository: repository,
          candidate: candidate,
          catalogDirectory: catalogDirectory))
    }
    return Report(
      catalogRef: options.catalogRef,
      catalogSHA256: maintenanceSHA256(catalogData),
      sources: results)
  }

  private func verifySource(
    _ source: PatchCatalog.Source,
    repository: URL,
    candidate: String,
    catalogDirectory: URL
  ) throws -> SourceReport {
    for commit in [source.upstreamCommit, source.forkCommit, candidate] {
      try verifyCommit(
        commit,
        repository: repository)
    }
    let targetTree = try git(["-C", repository.path, "rev-parse", "\(source.forkCommit)^{tree}"])
    try requireMaintenanceCondition(
      targetTree == source.expectedTree,
      "The recorded target tree differs from \(source.forkCommit).")
    let replay = try makeReplay(repository: repository)
    defer { replay.remove() }
    let prefix = replay.prefix
    let environment = replay.environment
    _ = try git(
      prefix + ["read-tree", source.upstreamCommit],
      environment: environment)
    let patches = try replaySeries(source, in: catalogDirectory, using: replay)
    let tree = try git(
      prefix + ["write-tree"],
      environment: environment)
    try requireMaintenanceCondition(
      tree == source.expectedTree, "The replayed target differs for \(source.repository).")
    let candidateTree = try git(
      prefix + ["rev-parse", "\(candidate)^{tree}"],
      environment: environment)
    var normalized: [String] = []
    var profilePatch: PatchReport?
    if let name = options.profiles[source.repository] {
      guard let profile = source.profiles.first(where: { $0.name == name }) else {
        throw MaintenanceError.failure(
          "Unlisted integration profile for \(source.repository): \(name).")
      }
      profilePatch = try verifyProfile(
        profile,
        candidate: candidate,
        candidateTree: candidateTree,
        catalogDirectory: catalogDirectory,
        replay: replay)
    } else {
      normalized = try compareCandidate(
        source,
        candidateTree: candidateTree,
        prefix: prefix,
        environment: environment)
    }
    return SourceReport(
      repository: source.repository,
      upstreamCommit: source.upstreamCommit,
      targetCommit: source.forkCommit,
      candidateCommit: candidate,
      replayedTree: tree,
      candidateTree: candidateTree,
      normalizedMetadataPaths: normalized,
      profile: options.profiles[source.repository],
      profilePatch: profilePatch,
      patches: patches)
  }

  private func replaySeries(
    _ source: PatchCatalog.Source,
    in catalogDirectory: URL,
    using replay: Replay
  ) throws -> [PatchReport] {
    let prefix = replay.prefix
    let environment = replay.environment
    var patches: [PatchReport] = []
    for patch in source.patches {
      let path = catalogDirectory.appendingPathComponent(patch.path).path
      _ = try git(
        prefix + ["apply", "--cached", "--check", path],
        environment: environment)
      let applied = try gitResult(
        prefix + ["apply", "--cached", path],
        environment: environment)
      let tree = try git(
        prefix + ["write-tree"],
        environment: environment)
      try requireMaintenanceCondition(
        tree == patch.expectedTree, "Replayed tree mismatch after \(patch.path): \(tree).")
      patches.append(
        PatchReport(
          path: patch.path,
          sha256: patch.sha256,
          tree: tree,
          warnings: applied.stderr))
    }
    return patches
  }
}
