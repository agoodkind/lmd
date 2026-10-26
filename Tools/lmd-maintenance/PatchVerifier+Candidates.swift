//
//  PatchVerifier+Candidates.swift
//  lmd-maintenance
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-10-25.
//  Copyright © 2026, all rights reserved.
//

import Foundation

extension PatchVerifier {
  func verifyProfile(
    _ profile: PatchCatalog.Profile,
    candidate: String,
    candidateTree: String,
    catalogDirectory: URL,
    replay: Replay
  ) throws -> PatchReport {
    let name = profile.name
    let prefix = replay.prefix
    let environment = replay.environment
    try requireMaintenanceCondition(
      candidate == profile.commit && candidateTree == profile.patch.expectedTree,
      "The selected candidate must equal the exact commit and tree for profile \(name).")
    let path = catalogDirectory.appendingPathComponent(profile.patch.path).path
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
      tree == profile.patch.expectedTree,
      "The integration profile delta does not reconstruct \(name).")
    return PatchReport(
      path: profile.patch.path,
      sha256: profile.patch.sha256,
      tree: tree,
      warnings: applied.stderr)
  }

  func compareCandidate(
    _ source: PatchCatalog.Source,
    candidateTree: String,
    prefix: [String],
    environment: [String: String]
  ) throws -> [String] {
    if candidateTree == source.expectedTree {
      return []
    }
    let (path, job) = try callerLocation(repository: source.repository)
    let changed = try git(
      prefix + [
        "diff-tree", "--no-commit-id", "--name-only", "-r", source.expectedTree, candidateTree,
      ],
      environment: environment)
    try requireMaintenanceCondition(
      changed == path,
      "Candidate changes require an explicit catalog update for \(source.repository): \(changed).")
    let originalEntry = try git(
      prefix + ["ls-tree", source.expectedTree, "--", path],
      environment: environment)
    let candidateEntry = try git(
      prefix + ["ls-tree", candidateTree, "--", path],
      environment: environment)
    try requireMaintenanceCondition(
      originalEntry.hasPrefix("100644 blob ") && candidateEntry.hasPrefix("100644 blob "),
      "The reusable workflow must remain a regular nonexecutable file: \(path).")
    let original = try gitResult(
      prefix + ["show", "\(source.expectedTree):\(path)"],
      environment: environment
    ).stdout
    let selected = try gitResult(
      prefix + ["show", "\(candidateTree):\(path)"],
      environment: environment
    ).stdout
    let allowed = try replacingCallerReferences(
      in: original,
      job: job)
    try requireMaintenanceCondition(
      selected == allowed,
      "Only the existing reusable workflow and lmd_ref SHA pair may change to \(options.catalogRef)."
    )
    _ = try git(
      prefix + ["read-tree", candidateTree],
      environment: environment)
    let originalBlob = try git(
      prefix + ["rev-parse", "\(source.expectedTree):\(path)"],
      environment: environment)
    _ = try git(
      prefix + ["update-index", "--cacheinfo", "100644", originalBlob, path],
      environment: environment)
    let normalizedTree = try git(
      prefix + ["write-tree"],
      environment: environment)
    try requireMaintenanceCondition(
      normalizedTree == source.expectedTree,
      "The normalized candidate tree differs from the catalog.")
    return [path]
  }

  private func callerLocation(repository: String) throws -> (String, String) {
    switch repository {
    case "agoodkind/mlx-swift":
      return (".github/workflows/downstream_integration.yml", "lmd_consumer")
    case "agoodkind/mlx-swift-lm":
      return (".github/workflows/downstream_integration.yml", "lmd-consumer")
    case "agoodkind/SwiftLM":
      return (".github/workflows/ci.yml", "lmd_consumer")
    default:
      throw MaintenanceError.failure("Unknown patch repository: \(repository).")
    }
  }

  private func replacingCallerReferences(
    in original: String,
    job: String
  ) throws -> String {
    let lines = original.components(separatedBy: "\n")
    let starts = lines.indices.filter { lines[$0] == "  \(job):" }
    try requireMaintenanceCondition(
      starts.count == 1, "The recorded reusable workflow job must exist once.")
    guard let start = starts.first else {
      throw MaintenanceError.failure("The recorded reusable workflow job is missing.")
    }
    var end = start + 1
    while end < lines.count {
      let line = lines[end]
      if line.hasPrefix("  "), let third = line.dropFirst(Self.jobIndentWidth).first,
        third != " ", third != "#"
      {
        break
      }
      end += 1
    }
    let block = lines[start..<end].joined(separator: "\n")
    let patterns = [
      "(?m)^    uses: agoodkind/lmd/\\.github/workflows/lmd_integration\\.yml@([0-9a-f]{40})$",
      "(?m)^      lmd_ref: ([0-9a-f]{40})$",
    ]
    var changed = block
    try requireMaintenanceCondition(
      block.components(separatedBy: "\n").filter { $0 == "    with:" }.count == 1,
      "The recorded reusable workflow job requires one with mapping.")
    for pattern in patterns {
      let regex = try NSRegularExpression(pattern: pattern)
      let matches = regex.matches(
        in: changed,
        range: NSRange(
          changed.startIndex...,
          in: changed))
      try requireMaintenanceCondition(
        matches.count == 1, "The recorded reusable workflow SHA pair is invalid.")
      guard let match = matches.first,
        let range = Range(
          match.range(at: 1),
          in: changed)
      else {
        throw MaintenanceError.failure("The recorded reusable workflow SHA is missing.")
      }
      changed.replaceSubrange(
        range,
        with: options.catalogRef)
    }
    var result = lines
    result.replaceSubrange(
      start..<end,
      with: changed.components(separatedBy: "\n"))
    return result.joined(separator: "\n")
  }

}
