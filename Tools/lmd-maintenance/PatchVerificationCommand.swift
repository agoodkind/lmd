//
//  PatchVerificationCommand.swift
//  lmd-maintenance
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-10-25.
//  Copyright © 2026, all rights reserved.
//

import Foundation
import SwiftMkCore

enum PatchVerificationCommand {
  struct Options {
    let catalog: URL
    let catalogRef: String
    let repositories: [String: URL]
    let candidates: [String: String]
    let profiles: [String: String]
    let report: URL

    private static let optionStride = 2

    init(_ arguments: [String]) throws {
      let required: Set<String> = [
        "--catalog", "--catalog-ref", "--core-repository", "--library-repository",
        "--swiftlm-repository", "--core-ref", "--library-ref", "--swiftlm-ref", "--report",
      ]
      let optional: Set<String> = ["--core-profile", "--library-profile", "--swiftlm-profile"]
      let allowed = required.union(optional)
      var values: [String: String] = [:]
      var index = 0
      while index < arguments.count {
        let option = arguments[index]
        try requireMaintenanceCondition(
          allowed.contains(option) && values[option] == nil && index + 1 < arguments.count,
          "Unknown, repeated, or incomplete patch verification option: \(option).")
        let value = arguments[index + 1]
        try requireMaintenanceCondition(
          !value.isEmpty || optional.contains(option), "\(option) requires a value.")
        if optional.contains(option) {
          try requireMaintenanceCondition(
            !value.contains(where: \.isWhitespace), "\(option) must not contain whitespace.")
        }
        values[option] = value
        index += Self.optionStride
      }
      for option in required {
        try requireMaintenanceCondition(
          values[option] != nil, "Missing required option: \(option).")
      }
      func value(_ option: String) throws -> String {
        guard let selectedValue = values[option] else {
          throw MaintenanceError.failure("Missing required option: \(option).")
        }
        return selectedValue
      }
      catalog = URL(fileURLWithPath: try value("--catalog")).standardizedFileURL
        .resolvingSymlinksInPath()
      catalogRef = try value("--catalog-ref")
      report = URL(fileURLWithPath: try value("--report")).standardizedFileURL
      var selectedRepositories: [String: URL] = [:]
      var selectedCandidates: [String: String] = [:]
      var selectedProfiles: [String: String] = [:]
      for (repository, label) in zip(PatchCatalog.repositories, ["core", "library", "swiftlm"]) {
        selectedRepositories[repository] = URL(
          fileURLWithPath: try value("--\(label)-repository")
        ).standardizedFileURL.resolvingSymlinksInPath()
        let candidate = try value("--\(label)-ref")
        try requireMaintenanceCondition(
          PatchCatalog.isHex(candidate, count: PatchCatalog.gitObjectIDLength),
          "--\(label)-ref requires a full commit SHA.")
        selectedCandidates[repository] = candidate
        if let profile = values["--\(label)-profile"], !profile.isEmpty {
          selectedProfiles[repository] = profile
        }
      }
      try requireMaintenanceCondition(
        PatchCatalog.isHex(catalogRef, count: PatchCatalog.gitObjectIDLength),
        "--catalog-ref requires a full commit SHA.")
      repositories = selectedRepositories
      candidates = selectedCandidates
      profiles = selectedProfiles
    }
  }

  static func run(_ arguments: [String]) throws {
    Output.debug("patches.verify_started")
    let options = try Options(arguments)
    let report = try PatchVerifier(options: options).verify()
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    try encoder.encode(report).write(to: options.report, options: .atomic)
    FileHandle.standardOutput.write(
      Data("Verified \(report.sources.count) patch series against selected candidate trees.\n".utf8)
    )
  }
}
