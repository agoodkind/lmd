//
//  DevTool+Notarize.swift
//  lmd-dev
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-05-10.
//  Copyright © 2026, all rights reserved.
//

import Foundation
import SwiftMkCore

// MARK: - NotarizeMode

enum NotarizeMode {
  case ci
  case local
}

// MARK: - Notarization

extension DevTool {
  func notarySetup() throws {
    let signing = try localSigningConfig()
    let appleID = signing["APPLE_ID"] ?? prompt("Apple ID email: ")
    guard !appleID.isEmpty else {
      throw ToolError.failure("notary-setup: Apple ID is required")
    }

    try writeLine(
      "[notary-setup] storing credentials in keychain profile: \(try signing.required("NOTARY_PROFILE"))"
    )
    try writeLine("[notary-setup] team: \(try signing.required("DEVELOPMENT_TEAM"))")
    try runPassthrough(
      "xcrun",
      [
        "notarytool",
        "store-credentials",
        try signing.required("NOTARY_PROFILE"),
        "--apple-id",
        appleID,
        "--team-id",
        try signing.required("DEVELOPMENT_TEAM"),
      ]
    )
  }

  func notarizeLocal() throws {
    try signLocal(targets: [])
    _ = try notarize(mode: .local)
  }

  @discardableResult
  func notarize(mode: NotarizeMode) throws -> URL {
    Output.debug("notarize mode=\(mode)")
    let scratch = try temporaryDirectory(prefix: "lmd-notarize")
    defer {
      do {
        try fileManager.removeItem(at: scratch)
      } catch {
        Output.warning("notarize scratch cleanup failed path=\(scratch.path) error=\(error)")
      }
    }

    try fileManager.createDirectory(at: productsDirectory(), withIntermediateDirectories: true)
    try stageSignedBinaries(into: scratch)

    let zipPath = productsDirectory().appendingPathComponent("lmd-\(artifactStamp()).zip")
    try runPassthrough(
      "/usr/bin/ditto", ["-c", "-k", "--keepParent", ".", zipPath.path], currentDirectory: scratch)

    // swift-mk's notarize command owns submission and the stapling policy;
    // the local mode resolves the keychain profile from signing.env and hands
    // it through NOTARY_PROFILE, while CI's APPLE_NOTARY_* trio is read by
    // swift-mk directly from the environment.
    var notarizeEnvironment = ProcessInfo.processInfo.environment
    if case .local = mode {
      let signing = try localSigningConfig()
      notarizeEnvironment["NOTARY_PROFILE"] = try signing.required("NOTARY_PROFILE")
    }
    guard let swiftMk = swiftMkBinaryPath() else {
      throw ToolError.failure("notarize: swift-mk binary not found; run make swift-mk-bin")
    }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: swiftMk)
    process.arguments = ["notarize", zipPath.path]
    process.environment = notarizeEnvironment
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
      throw ToolError.failure("notarize: swift-mk notarize failed for \(zipPath.path)")
    }
    if case .ci = mode {
      try appendGitHubOutput(name: "artifact", value: zipPath.path)
    }

    return zipPath
  }

  func stageSignedBinaries(into directory: URL) throws {
    Output.debug("stageSignedBinaries directory=\(directory.path)")
    for binary in productBinaries {
      let source = releaseBuildDirectory().appendingPathComponent(binary)
      guard fileManager.fileExists(atPath: source.path) else {
        throw ToolError.failure("[notarize] missing \(source.path); run sign first")
      }
      try runPassthrough("codesign", ["--verify", "--strict", source.path])
      try copyReplacingItem(at: source, to: directory.appendingPathComponent(binary))
    }
    try stageCompatibilityLinks(in: directory)
    try copyRuntimeResources(from: releaseBuildDirectory(), to: directory)
    for bundle in resourceBundlesToSign() {
      try runPassthrough("codesign", ["--verify", "--strict", bundle.path])
    }
    try stageSwiftLMForNotarize(into: directory)
  }

  /// Copy the staged SwiftLM subdirectory (chat binary plus its metallib) into the
  /// notarize scratch dir and verify the signed binary, so it rides in the same
  /// zip as lmd's CLIs. `ci-sign` signed the SwiftLM Mach-O via
  /// `SWIFT_MK_SIGN_PRODUCTS`; the metallib ships unsigned as data covered by the
  /// zip's notarization.
  private func stageSwiftLMForNotarize(into directory: URL) throws {
    Output.debug("stageSwiftLMForNotarize directory=\(directory.path)")
    let staged = releaseBuildDirectory().appendingPathComponent("swiftlm")
    guard fileManager.fileExists(atPath: staged.path) else {
      throw ToolError.failure("[notarize] SwiftLM not staged at \(staged.path); run build first")
    }
    let binary = staged.appendingPathComponent("SwiftLM")
    guard fileManager.fileExists(atPath: binary.path) else {
      throw ToolError.failure("[notarize] missing \(binary.path); run sign first")
    }
    try runPassthrough("codesign", ["--verify", "--strict", binary.path])
    try copyReplacingItem(at: staged, to: directory.appendingPathComponent("swiftlm"))
  }
}
