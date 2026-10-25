//
//  PatchCatalog.swift
//  lmd-maintenance
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-10-25.
//  Copyright © 2026, all rights reserved.
//

import Foundation

struct PatchCatalog: Codable {
  let version: Int
  let sources: [Source]
  let protections: [Protection]

  struct Source: Codable {
    let repository: String
    let upstreamRepository: String
    let upstreamCommit: String
    let forkCommit: String
    let expectedTree: String
    let patches: [Patch]
    let profiles: [Profile]

    enum CodingKeys: String, CodingKey {
      case repository, patches, profiles
      case upstreamRepository = "upstream_repository"
      case upstreamCommit = "upstream_commit"
      case forkCommit = "fork_commit"
      case expectedTree = "expected_tree"
    }
  }

  struct Profile: Codable {
    let name: String
    let commit: String
    let patch: Patch
  }

  struct Patch: Codable {
    let path: String
    let sha256: String
    let expectedTree: String

    enum CodingKeys: String, CodingKey {
      case path, sha256
      case expectedTree = "expected_tree"
    }
  }

  struct Protection: Codable {
    let feature: String
    let repository: String
    let selectors: [String]
  }

  static let repositories = [
    "agoodkind/mlx-swift", "agoodkind/mlx-swift-lm", "agoodkind/SwiftLM",
  ]

  static let gitObjectIDLength = 40
  private static let checksumLength = 64
  private static let patchPathComponentCount = 2

  static func isHex(_ value: String, count: Int) -> Bool {
    let characters = Set("0123456789abcdef".utf8)
    return value.utf8.count == count && value.utf8.allSatisfy(characters.contains)
  }

  func validate() throws {
    try requireMaintenanceCondition(version == 1, "The patch catalog version must be 1.")
    try requireMaintenanceCondition(
      sources.map(\.repository) == Self.repositories,
      "The patch catalog must contain core, library, and SwiftLM in that order.")
    for source in sources {
      try validateSource(source)
    }
    try requireMaintenanceCondition(!protections.isEmpty, "The patch catalog requires protections.")
    for protection in protections {
      try requireMaintenanceCondition(
        Self.repositories.contains(protection.repository) && !protection.feature.isEmpty
          && !protection.selectors.isEmpty && protection.selectors.allSatisfy { !$0.isEmpty },
        "Each protection requires a known repository, feature, and test selectors.")
    }
  }

  private func validateSource(_ source: Source) throws {
    for commit in [source.upstreamCommit, source.forkCommit, source.expectedTree] {
      try requireMaintenanceCondition(
        Self.isHex(commit, count: Self.gitObjectIDLength),
        "Invalid Git object ID in \(source.repository).")
    }
    try requireMaintenanceCondition(
      !source.upstreamRepository.isEmpty && !source.patches.isEmpty,
      "\(source.repository) requires an upstream repository and an ordered patch series.")
    let directory = String(source.repository.split(separator: "/").last ?? "")
    for (offset, patch) in source.patches.enumerated() {
      let prefix = String(format: "%@/%04d-", directory, offset + 1)
      try validatePatch(patch, prefix: prefix)
    }
    try requireMaintenanceCondition(
      source.patches.last?.expectedTree == source.expectedTree,
      "The final patch tree must match the target for \(source.repository).")
    try requireMaintenanceCondition(
      Set(source.profiles.map(\.name)).count == source.profiles.count,
      "Integration profile names must be unique for \(source.repository).")
    for profile in source.profiles {
      try validateProfile(profile)
    }
  }

  private func validatePatch(_ patch: Patch, prefix: String) throws {
    try requireMaintenanceCondition(
      patch.path.hasPrefix(prefix) && patch.path.hasSuffix(".patch")
        && patch.path.split(separator: "/").count == Self.patchPathComponentCount
        && !patch.path.contains(".."),
      "The patch series has a missing or reordered entry: \(patch.path).")
    try requireMaintenanceCondition(
      Self.isHex(patch.sha256, count: Self.checksumLength)
        && Self.isHex(patch.expectedTree, count: Self.gitObjectIDLength),
      "Invalid checksum or tree ID for \(patch.path).")
  }

  private func validateProfile(_ profile: Profile) throws {
    try requireMaintenanceCondition(
      !profile.name.isEmpty && Self.isHex(profile.commit, count: Self.gitObjectIDLength)
        && !profile.name.contains("/") && !profile.name.contains(".."),
      "Invalid integration profile name or commit: \(profile.name).")
    try requireMaintenanceCondition(
      Self.isHex(profile.patch.sha256, count: Self.checksumLength)
        && Self.isHex(profile.patch.expectedTree, count: Self.gitObjectIDLength)
        && profile.patch.path == "profiles/\(profile.name).patch",
      "Invalid integration profile patch: \(profile.name).")
  }
}
