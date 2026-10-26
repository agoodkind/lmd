//
//  DependencyVersionsContext+Preparation.swift
//  lmd-maintenance
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-10-25.
//  Copyright © 2026, all rights reserved.
//

import Foundation
import SwiftMkCore

// MARK: - Manifests and dependency resolution

extension DependencyVersionsContext {
  func pinManifest(_ path: URL, identity: String, revision: String) throws -> String {
    Output.debug("versions.manifest.pin path=\(path.path) identity=\(identity)")
    let text = try String(contentsOf: path, encoding: .utf8)
    let pattern =
      "(url:\\s*\"https://github\\.com/agoodkind/"
      + NSRegularExpression.escapedPattern(for: identity)
      + "(?:\\.git)?\",\\s*revision:\\s*\")([0-9a-f]{40})(\")"
    let expression = try NSRegularExpression(pattern: pattern)
    let matches = expression.matches(in: text, range: NSRange(text.startIndex..., in: text))
    try requireMaintenanceCondition(
      matches.count == 1, "Expected one immutable \(identity) requirement in \(path.path)")
    let mutable = NSMutableString(string: text)
    let revisionCaptureGroup = 2
    let previous = mutable.substring(with: matches[0].range(at: revisionCaptureGroup))
    mutable.replaceCharacters(in: matches[0].range(at: revisionCaptureGroup), with: revision)
    try (mutable as String).write(to: path, atomically: true, encoding: .utf8)
    return previous
  }

  func configureMirrors(exportToRunner: Bool) throws {
    Output.debug("versions.mirrors.configure")
    guard let initial = Int(environment["GIT_CONFIG_COUNT"] ?? "0"), initial >= 0 else {
      throw MaintenanceError.failure("GIT_CONFIG_COUNT must be a nonnegative integer")
    }
    var entries = [("protocol.file.allow", "always")]
    for (identity, directory) in [("mlx-swift", core), ("mlx-swift-lm", library)] {
      for suffix in ["", ".git"] {
        entries.append(
          (
            "url.\(directory.absoluteString).insteadOf",
            "https://github.com/agoodkind/\(identity)\(suffix)"
          ))
      }
    }
    var lines: [String] = []
    for (offset, entry) in entries.enumerated() {
      let index = initial + offset
      environment["GIT_CONFIG_KEY_\(index)"] = entry.0
      environment["GIT_CONFIG_VALUE_\(index)"] = entry.1
      lines.append("GIT_CONFIG_KEY_\(index)=\(entry.0)")
      lines.append("GIT_CONFIG_VALUE_\(index)=\(entry.1)")
    }
    environment["GIT_CONFIG_COUNT"] = String(initial + entries.count)
    lines.append("GIT_CONFIG_COUNT=\(initial + entries.count)")
    if exportToRunner, let path = environment["GITHUB_ENV"] {
      try withWritableFile(URL(fileURLWithPath: path)) { handle in
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((lines.joined(separator: "\n") + "\n").utf8))
      }
    }
  }

  func prepare() throws {
    Output.debug("versions.prepare root=\(root.path)")
    try validateOriginalSources()
    try FileManager.default.createDirectory(at: proof, withIntermediateDirectories: true)
    let state = try prepareLibrary()
    try archiveBaselines()
    try writeJSON(state, to: stateURL)
    for packagePath in ["", "Tuist"] {
      let manifest = root.appendingPathComponent(packagePath).appendingPathComponent(
        "Package.swift")
      _ = try pinManifest(manifest, identity: "mlx-swift", revision: state.newCoreRequirement)
      _ = try pinManifest(manifest, identity: "mlx-swift-lm", revision: state.effectiveLibrary)
    }
    try configureMirrors(exportToRunner: true)
    try bindSwiftLM(state)
    for packagePath in packagePaths {
      try command(
        root,
        "swift",
        [
          "package", "--package-path", root.appendingPathComponent(packagePath).path,
          "--jobs", "4", "resolve",
        ],
        streaming: true)
    }
    try verify()
  }

  private func validateOriginalSources() throws {
    for (directory, key) in [
      (root, "LMD_REF"), (core, "CORE_REF"), (library, "LIBRARY_REF"),
      (root.appendingPathComponent("SwiftLM"), "SWIFTLM_REF"),
    ] {
      try requireMaintenanceCondition(
        try git(directory, ["rev-parse", "HEAD"]) == ref(key),
        "Unexpected source commit in \(directory.path)")
    }
    try requireMaintenanceCondition(
      try git(library, ["status", "--porcelain"]).isEmpty,
      "The dedicated library checkout must be clean")
  }

  private func commitLibraryOverlay(base: String, overlayData: Data) throws -> String {
    var effective = base
    if !overlayData.isEmpty {
      try requireMaintenanceCondition(
        try git(library, ["diff", "--name-only"]) == "Package.swift",
        "The library overlay changed more than Package.swift")
      try git(library, ["add", "Package.swift"])
      let tree = try git(library, ["write-tree"])
      effective = try git(
        library,
        [
          "-c", "user.name=CI versions preparation", "-c", "user.email=noreply@github.com",
          "commit-tree", tree, "-p", base, "-m",
          "Prepare the CI core requirement\n\nCo-authored-by: Codex <noreply@openai.com>",
        ])
      try git(library, ["checkout", "--detach", effective])
      try git(library, ["update-ref", "refs/tags/ci-versions-" + effective, effective])
    }
    return effective
  }

  private func prepareLibrary() throws -> DependencyVersionsState {
    Output.debug("versions.library.prepare path=\(library.path)")
    let coreRevision = try ref("CORE_REF")
    let base = try ref("LIBRARY_REF")
    let previous = try pinManifest(
      library.appendingPathComponent("Package.swift"), identity: "mlx-swift", revision: coreRevision
    )
    let overlay = proof.appendingPathComponent("library-overlay.patch")
    try gitArchive(library, ["diff", "--binary", "--full-index", base], destination: overlay)
    let overlayData = try Data(contentsOf: overlay)
    let effective = try commitLibraryOverlay(base: base, overlayData: overlayData)
    try git(library, ["diff", "--exit-code", base, effective, "--", ".", ":!Package.swift"])
    let commitURL = proof.appendingPathComponent("library-commit-object.txt")
    try gitArchive(library, ["cat-file", "commit", effective], destination: commitURL)
    try requireMaintenanceCondition(
      try git(library, ["hash-object", "-t", "commit", commitURL.path]) == effective,
      "Archived commit bytes do not match the effective library revision")
    return DependencyVersionsState(
      libraryCommitSha256: maintenanceSHA256(try Data(contentsOf: commitURL)),
      requested: refs,
      effectiveLibrary: effective,
      libraryBase: base,
      oldCoreRequirement: previous,
      newCoreRequirement: coreRevision,
      libraryOverlaySha256: maintenanceSHA256(overlayData),
      libraryOverlayTree: try git(library, ["rev-parse", effective + "^{tree}"]),
      libraryOverlayRef: effective == base ? nil : "refs/tags/ci-versions-" + effective,
      runtimeSourceComparison: "git diff --exit-code base effective -- . :!Package.swift passed",
      mirrors: ["mlx-swift": core.absoluteString, "mlx-swift-lm": library.absoluteString])
  }

  private func archiveBaselines() throws {
    for packagePath in packagePaths {
      let relative = packagePath.isEmpty ? "Package.resolved" : packagePath + "/Package.resolved"
      try gitArchive(
        root,
        ["show", try ref("LMD_REF") + ":" + relative],
        destination: proof.appendingPathComponent("baseline-" + lockName(packagePath)))
    }
    try gitArchive(
      root.appendingPathComponent("SwiftLM"),
      ["show", try ref("SWIFTLM_REF") + ":Package.resolved"],
      destination: proof.appendingPathComponent("baseline-swiftlm-Package.resolved"))
  }

  private func bindSwiftLM(_ state: DependencyVersionsState) throws {
    try git(root, ["update-index", "--cacheinfo", "160000," + ref("SWIFTLM_REF") + ",SwiftLM"])
    try command(
      root, "git", ["submodule", "update", "--init", "--recursive", "SwiftLM"], streaming: true)
    for (identity, directory, revision) in [
      ("mlx-swift", core, state.newCoreRequirement),
      ("mlx-swift-lm", library, state.effectiveLibrary),
    ] {
      let nested = root.appendingPathComponent("SwiftLM/" + identity)
      try git(nested, ["fetch", "--no-tags", directory.path, revision])
      try git(nested, ["checkout", "--detach", revision])
    }
  }
}
