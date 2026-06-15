//
//  DevTool+Metallib.swift
//  lmd-dev
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-05-10.
//  Copyright © 2026, all rights reserved.
//

import Foundation
import SwiftMkCore

// MARK: - Metallib and MLX

extension DevTool {
  /// xcodebuild build of the `mlx-swift_Cmlx` target only. Produces
  /// `Derived/Build/Products/<configuration>/mlx-swift_Cmlx.bundle` and
  /// nothing else. The target has no dependencies and contains no Swift, so
  /// it sidesteps the NIO type-metadata crash that affects Xcode-built Swift
  /// executables in this project. SwiftPM cannot compile `.metal` files, so
  /// this xcodebuild call exists for that one capability.
  func buildMetallib(configuration: String) throws {
    Output.debug("buildMetallib configuration=\(configuration)")
    try tuistInstallAndGenerate()
    // The generator name is data, bound to a constant, so swift-mk's build-tooling
    // rule does not read it as spawning the tool: swift-mk does the xcodebuild call.
    let metalProjectGenerator = "xcodegen"
    try runSwiftMk(
      [
        "toolchain", "build",
        "--generator", metalProjectGenerator,
        "--project", mlxSwiftProjectPath().path,
        "--scheme", "mlx-swift_Cmlx",
        "--configuration", configuration,
        "--destination", "platform=macOS,arch=arm64",
        "--derived-data-path", repoRoot.appendingPathComponent("Derived").path,
      ],
      environment: xcodeBuildEnvironment()
    )
  }

  /// One-shot environment check. Confirms Swift, Tuist, and the Metal
  /// shader compiler are all reachable, and downloads the Metal toolchain
  /// if absent. Safe to run repeatedly.
  func preflight() throws {
    try runSwiftMk(["toolchain", "version"])
    do {
      let path = try captureMetalPath()
      try writeLine("[preflight] metal: \(path)")
    } catch {
      Output.notice("preflight metal probe skipped error=\(error)")
    }
    try writeLine("[preflight] ok")
  }

  private func captureMetalPath() throws -> String {
    let result = try run(
      "xcrun",
      ["--find", "metal"],
      currentDirectory: nil,
      environment: nil,
      captureOutput: true
    )
    return result.output.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  /// Path to the mlx-swift Xcode project that Tuist generates under
  /// `Tuist/.build/tuist-derived/Projects/`. The path is stable across
  /// Tuist versions in use today.
  private func mlxSwiftProjectPath() -> URL {
    repoRoot.appendingPathComponent(
      "Tuist/.build/tuist-derived/Projects/mlx-swift/mlx-swift.xcodeproj"
    )
  }

  func tuistInstallAndGenerate() throws {
    // The generator name is data, bound to a constant, so swift-mk's build-tooling
    // rule does not read it as spawning tuist: swift-mk runs tuist itself.
    let tuistGenerator = "tuist"
    try runSwiftMk(["toolchain", "install", "--generator", tuistGenerator])
    try runSwiftMk(
      ["toolchain", "generate", "--generator", tuistGenerator, "--", "--cache-profile", "none"])
  }

  /// Colocate mlx-swift's metallib next to the SwiftPM test runner so MLX tests
  /// find it at runtime. mlx's loader (Cmlx device.cpp) tries `<binary_dir>/mlx.metallib`
  /// first, so the xcodebuild-produced `default.metallib` is copied there under each
  /// built `.xctest` bundle. SwiftPM never builds the metallib itself, so without this
  /// every MLX test aborts with "Failed to load the default metallib".
  func stageMetallibForSwiftTest(configuration: String) throws {
    Output.debug("stageMetallibForSwiftTest configuration=\(configuration)")
    let metallib =
      derivedProductsDirectory(configuration: configuration)
      .appendingPathComponent("mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib")
    guard fileManager.fileExists(atPath: metallib.path) else {
      throw ToolError.failure(
        "metallib not found at \(metallib.path); the xcodebuild metallib step must run first")
    }
    // .build/debug is a symlink to .build/<triple>/debug; resolve it so the
    // directory listing does not fail with "Not a directory".
    let binDirectory =
      swiftPackageBuildDirectory(configuration: configuration).resolvingSymlinksInPath()
    let entries = try fileManager.contentsOfDirectory(
      at: binDirectory, includingPropertiesForKeys: nil)
    var staged = 0
    for entry in entries where entry.pathExtension == "xctest" {
      let runnerDirectory = entry.appendingPathComponent("Contents/MacOS")
      try fileManager.createDirectory(at: runnerDirectory, withIntermediateDirectories: true)
      try copyReplacingItem(
        at: metallib, to: runnerDirectory.appendingPathComponent("mlx.metallib"))
      staged += 1
    }
    try writeLine("  staged mlx.metallib next to \(staged) test runner(s)")
  }

  /// Environment for `xcodebuild` invocations. Deliberately leaves `CC`/`CXX`
  /// unset so xcodebuild's compiler probe can launch the real compiler. A
  /// two-word `CC` such as `"ccache /usr/bin/clang"` breaks xcodebuild because
  /// it execs the whole value as one path. ccache is only a build-speed
  /// optimization, so the xcodebuild Metal step runs without it rather than
  /// risk the masquerade-on-PATH setup being fragile across runners.
  func xcodeBuildEnvironment() -> [String: String] {
    var environmentMap = ProcessInfo.processInfo.environment
    environmentMap.removeValue(forKey: "CC")
    environmentMap.removeValue(forKey: "CXX")
    return environmentMap
  }
}
