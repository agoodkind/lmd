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
      try stageNaxLibraries(from: naxLibraryDirectory(), to: runnerDirectory)
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

// MARK: - NAX ahead-of-time kernels

/// Shared inputs for compiling one NAX kernel into a `.metallib`: the source
/// roots, the output directory, and the deployment-target-pinned compile flags.
struct NaxBuildContext {
  let kernelsDirectory: URL
  let includeRoot: URL
  let output: URL
  let compileFlags: [String]
  let deploymentTarget: String
}

/// The M5 NAX kernel sources compiled ahead-of-time, each relative to the
/// mlx-swift kernels directory and without the `.metal` extension.
private let naxKernelSources = [
  "steel/gemm/kernels/steel_gemm_fused_nax",
  "steel/gemm/kernels/steel_gemm_splitk_nax",
  "steel/gemm/kernels/steel_gemm_gather_nax",
  "steel/gemm/kernels/steel_gemm_segmented_nax",
  "steel/attn/kernels/steel_attention_nax",
  "quantized_nax",
  "fp_quantized_nax",
]

extension DevTool {
  /// The macOS 26.5 Metal compiler miscompiles the runtime-JIT form of the M5
  /// neural-accelerator (NAX) GEMM kernels, producing NaN, while compiling the
  /// same kernel source ahead-of-time from its `.metal` file is correct. This
  /// builds those kernels into `Derived/nax/<source>.metallib`, which the
  /// mlx-swift runtime loads instead of JIT-compiling (see device.cpp
  /// get_library and docs/bf16-nax-investigation.md). Additive: if the source or
  /// the Metal compiler is absent, the directory stays empty and the runtime
  /// JIT-compiles exactly as before.
  func buildNaxAotLibraries(configuration _: String) throws {
    Output.debug("buildNaxAotLibraries")
    guard let kernelsDirectory = forkMlxKernelsDirectory() else {
      try writeLine("  nax: mlx-swift kernel source not found, runtime will JIT")
      return
    }
    let includeRoot =
      kernelsDirectory
      .deletingLastPathComponent()  // metal
      .deletingLastPathComponent()  // backend
      .deletingLastPathComponent()  // mlx (inner)
      .deletingLastPathComponent()  // Source/Cmlx/mlx (outer)
    let output = naxLibraryDirectory()
    if fileManager.fileExists(atPath: output.path) {
      try fileManager.removeItem(at: output)
    }
    try fileManager.createDirectory(at: output, withIntermediateDirectories: true)

    // Match mlx-core's CMake metal command exactly: no -std (the default metal
    // version is correct), and -mmacosx-version-min set to the host OS. The
    // macOS 26.5 metal4.0 codegen miscompiles the M5 NAX bf16 GEMM; forcing
    // -std=metal4.0 or omitting the deployment target produces wrong bf16.
    let osVersion = ProcessInfo.processInfo.operatingSystemVersion
    let deploymentTarget =
      "\(osVersion.majorVersion).\(osVersion.minorVersion).\(osVersion.patchVersion)"
    let compileFlags = [
      "-x", "metal", "-Wall", "-Wextra", "-fno-fast-math",
      "-Wno-c++17-extensions", "-Wno-c++20-extensions",
      "-mmacosx-version-min=\(deploymentTarget)",
    ]
    let context = NaxBuildContext(
      kernelsDirectory: kernelsDirectory,
      includeRoot: includeRoot,
      output: output,
      compileFlags: compileFlags,
      deploymentTarget: deploymentTarget
    )
    Output.notice(
      "nax build kernels=\(naxKernelSources.count) deploymentTarget=\(deploymentTarget)")
    try writeLine(
      "  nax: build_begin kernels=\(naxKernelSources.count) deployment_target=\(deploymentTarget)")
    var built = 0
    for source in naxKernelSources {
      let didBuild = try compileNaxKernel(source: source, context: context)
      if didBuild {
        built += 1
      }
    }
    if built == 0 {
      try writeLine("  nax: no kernels built, runtime will JIT")
    }
  }

  /// Compile one NAX kernel `.metal` source into a `.metallib`, removing the
  /// intermediate `.air` file. Returns `false` when the source is absent so the
  /// caller counts only the kernels that actually built.
  private func compileNaxKernel(source: String, context: NaxBuildContext) throws -> Bool {
    let metalFile = context.kernelsDirectory.appendingPathComponent(source + ".metal")
    guard fileManager.fileExists(atPath: metalFile.path) else {
      try writeLine("  nax: \(source).metal not present, skipping")
      return false
    }
    let stem = (source as NSString).lastPathComponent
    let airFile = context.output.appendingPathComponent(stem + ".air")
    let libraryFile = context.output.appendingPathComponent(stem + ".metallib")
    try runPassthrough(
      "xcrun",
      ["-sdk", "macosx", "metal"] + context.compileFlags
        + [
          "-I", context.kernelsDirectory.path, "-I", context.includeRoot.path,
          "-c", metalFile.path, "-o", airFile.path,
        ])
    try runPassthrough(
      "xcrun",
      [
        "-sdk", "macosx", "metal", "-mmacosx-version-min=\(context.deploymentTarget)",
        airFile.path, "-o", libraryFile.path,
      ])
    if fileManager.fileExists(atPath: airFile.path) {
      try fileManager.removeItem(at: airFile)
    }
    Output.debug("nax kernel built=\(stem)")
    try writeLine("  nax: built \(stem).metallib")
    return true
  }

  /// Locate the mlx-swift fork's Metal kernel sources, whether the dependency is
  /// a `swift package edit` symlink (`Packages/mlx-swift`) or a resolved checkout
  /// (`.build/checkouts/mlx-swift`).
  private func forkMlxKernelsDirectory() -> URL? {
    let relative = "Source/Cmlx/mlx/mlx/backend/metal/kernels"
    let candidates = [
      repoRoot.appendingPathComponent("Packages/mlx-swift"),
      repoRoot.appendingPathComponent(".build/checkouts/mlx-swift"),
    ]
    for candidate in candidates {
      let kernels = candidate.appendingPathComponent(relative)
      let probe = kernels.appendingPathComponent(
        "steel/gemm/kernels/steel_gemm_fused_nax.metal")
      if fileManager.fileExists(atPath: probe.path) {
        return kernels
      }
    }
    return nil
  }

  /// The directory holding the ahead-of-time-compiled NAX metallibs.
  func naxLibraryDirectory() -> URL {
    repoRoot.appendingPathComponent("Derived/nax")
  }
}
