//
//  DevTool+Signing.swift
//  lmd-dev
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-05-10.
//  Copyright © 2026, all rights reserved.
//

import Foundation
import SwiftMkCore

// MARK: - Signing

extension DevTool {
  func signLocal(targets: [String]) throws {
    let signing = try localSigningConfig()
    let selectedTargets = targets.isEmpty ? productBinaries : targets
    let identity = signingIdentityThroughSwiftMk(
      source: try signing.required("CODE_SIGN_IDENTITY"),
      team: signing["DEVELOPMENT_TEAM"])
    try signTargets(
      selectedTargets,
      identity: identity,
      bundleIdentifierPrefix: try signing.required("BUNDLE_ID_PREFIX")
    )
  }

  func signCI() throws {
    // swift-mk's canonical signing variable names come first; the APPLE_*
    // names stay as a fallback for older local environments.
    let identityCandidates = [
      environment.values["CODE_SIGN_IDENTITY"],
      environment.values["APPLE_CODE_SIGN_IDENTITY"],
    ]
    guard
      let identitySource = identityCandidates.compactMap(\.self).first(where: { !$0.isEmpty })
    else {
      throw ToolError.failure("ci-sign: CODE_SIGN_IDENTITY is required")
    }
    let teamCandidates = [
      environment.values["DEVELOPMENT_TEAM"],
      environment.values["APPLE_TEAM_ID"],
    ]
    let team = teamCandidates.compactMap(\.self).first { !$0.isEmpty }
    let identity = signingIdentityThroughSwiftMk(source: identitySource, team: team)
    try signTargets(
      productBinaries,
      identity: identity,
      bundleIdentifierPrefix: defaultBundleIdentifierPrefix
    )
  }

  /// Resolve the code-signing identity through swift-mk so this post-build
  /// codesign uses the same identity resolution as the xcodebuild consumers.
  /// swift-mk reads SWIFT_MK_SIGN_IDENTITY then CODE_SIGN_IDENTITY, so the source
  /// identity and team are exported before asking it. Falls back to `source` when
  /// no swift-mk binary is found or it resolves nothing, so signing never breaks.
  func signingIdentityThroughSwiftMk(source: String, team: String?) -> String {
    Output.debug("signingIdentityThroughSwiftMk")
    guard let swiftMk = swiftMkBinaryPath() else {
      return source
    }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: swiftMk)
    process.arguments = ["signing-identity"]
    var env = ProcessInfo.processInfo.environment
    env["CODE_SIGN_IDENTITY"] = source
    if let team, !team.isEmpty {
      env["DEVELOPMENT_TEAM"] = team
    }
    process.environment = env
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    do {
      try process.run()
    } catch {
      Output.notice("signing-identity launch failed error=\(error)")
      return source
    }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    let resolved = (String(data: data, encoding: .utf8) ?? "")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return resolved.isEmpty ? source : resolved
  }

  /// Locate the swift-mk binary: SWIFT_MK_BIN if set and executable, else the
  /// first `swift-mk` on PATH. Returns nil when neither is available.
  func swiftMkBinaryPath() -> String? {
    Output.debug("swiftMkBinaryPath")
    if let bin = environment.values["SWIFT_MK_BIN"],
      fileManager.isExecutableFile(atPath: bin)
    {
      return bin
    }
    let probe = Process()
    probe.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    probe.arguments = ["command", "-v", "swift-mk"]
    let pipe = Pipe()
    probe.standardOutput = pipe
    probe.standardError = FileHandle.nullDevice
    do {
      try probe.run()
    } catch {
      Output.notice("swift-mk probe launch failed error=\(error)")
      return nil
    }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    probe.waitUntilExit()
    guard probe.terminationStatus == 0 else {
      return nil
    }
    let path = (String(data: data, encoding: .utf8) ?? "")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return path.isEmpty ? nil : path
  }

  /// Run `swift-mk <arguments>` so the build routes its toolchain (tuist/xcodebuild)
  /// through the swift-mk chokepoint instead of naming those tools here. Fails when
  /// swift-mk is not resolvable, since the build cannot route without it.
  @discardableResult
  func runSwiftMk(_ arguments: [String], environment env: [String: String]? = nil) throws
    -> CommandResult
  {
    guard let bin = swiftMkBinaryPath() else {
      throw ToolError.failure(
        "swift-mk not found (set SWIFT_MK_BIN or install swift-mk); the build routes its "
          + "toolchain through swift-mk")
    }
    return try runPassthrough(bin, arguments, environment: env)
  }
}

// MARK: - Codesign targets

extension DevTool {
  func signTargets(
    _ targets: [String],
    identity: String,
    bundleIdentifierPrefix: String
  ) throws {
    for target in targets {
      let inputURL = URL(fileURLWithPath: target, relativeTo: repoRoot).standardizedFileURL
      let binaryPath =
        fileManager.fileExists(atPath: inputURL.path)
        ? inputURL
        : releaseBuildDirectory().appendingPathComponent(target)
      try signPath(
        binaryPath,
        identity: identity,
        identifier: "\(bundleIdentifierPrefix).\(binaryPath.lastPathComponent)"
      )
    }
    for bundle in resourceBundlesToSign() {
      let bundleName = bundle.deletingPathExtension().lastPathComponent
      try signPath(
        bundle,
        identity: identity,
        identifier: "\(bundleIdentifierPrefix).\(bundleName)"
      )
    }
  }

  /// Codesign a single Mach-O or bundle with the Hardened Runtime and a
  /// secure timestamp, then verify the signature.
  func signPath(_ path: URL, identity: String, identifier: String) throws {
    Output.debug("signPath path=\(path.path) identifier=\(identifier)")
    guard fileManager.fileExists(atPath: path.path) else {
      throw ToolError.failure("sign: not found: \(path.path)")
    }
    // swift-mk's codesign-run owns the canonical flags and the strict verify;
    // the resolved identity rides in through SWIFT_MK_SIGN_IDENTITY so lmd's
    // signing.env source keeps working. There is no direct-codesign fallback:
    // a checkout without the binary runs make first.
    guard let swiftMk = swiftMkBinaryPath() else {
      throw ToolError.failure("sign: swift-mk binary not found; run make swift-mk-bin")
    }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: swiftMk)
    process.arguments = [
      "codesign-run", "--mode", "binary", "--identifier", identifier, path.path,
    ]
    var processEnvironment = ProcessInfo.processInfo.environment
    processEnvironment["SWIFT_MK_SIGN_IDENTITY"] = identity
    process.environment = processEnvironment
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
      throw ToolError.failure("sign: swift-mk codesign-run failed for \(path.path)")
    }
  }

  /// Resource bundles in the staged release directory that need a real
  /// signature for notarization. Today this is just the MLX shader bundle,
  /// but any future `*.bundle` Tuist drops alongside the binaries gets
  /// picked up automatically.
  func resourceBundlesToSign() -> [URL] {
    let staging = releaseBuildDirectory()
    let contents: [URL]
    do {
      contents = try fileManager.contentsOfDirectory(
        at: staging,
        includingPropertiesForKeys: nil
      )
    } catch {
      Output.notice("resourceBundlesToSign listing failed dir=\(staging.path) error=\(error)")
      return []
    }
    return contents.filter { $0.pathExtension == "bundle" }
  }

  func localSigningConfig() throws -> [String: String] {
    let signingURL = repoRoot.appendingPathComponent("config/signing.env")
    guard fileManager.fileExists(atPath: signingURL.path) else {
      throw ToolError.failure(
        "missing \(signingURL.path); cp config/signing.env.example config/signing.env and fill in your values"
      )
    }
    return try parseKeyValueFile(signingURL)
  }
}
