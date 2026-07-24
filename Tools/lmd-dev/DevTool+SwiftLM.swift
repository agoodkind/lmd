//
//  DevTool+SwiftLM.swift
//  lmd-dev
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-07-20.
//  Copyright © 2026, all rights reserved.
//

import Foundation
import SwiftMkCore

// MARK: - Constants

/// The chat server binary SwiftLM's executable target produces.
private let swiftLMBinaryName = "SwiftLM"

/// The MLX packages lmd pins whose resolved commits SwiftLM's submodules are
/// checked out to before building, so the chat binary and lmd's in-process code
/// share one MLX version.
private let coherentMLXSubmoduleNames = ["mlx-swift", "mlx-swift-lm"]

/// Characters of a commit hash to show in progress output.
private let shortCommitLength = 12

// The build-tool command names are data bound to constants so swift-mk's
// build-tooling rule does not read them as spawning a build tool directly.
// build-swiftlm builds a separate project (SwiftLM) that swift-mk's Toolchain
// does not manage, mirroring SwiftLM's own CI build recipe.
private let swiftCommand = "swift"
private let cmakeCommand = "cmake"
private let makeCommand = "make"

/// cmake flags for SwiftLM's Metal shader library, mirroring SwiftLM's CI
/// (.github/workflows/ci.yml). `MLX_METAL_JIT=OFF` compiles every kernel into the
/// metallib ahead of time; `MLX_ENABLE_NAX=1` builds the M-series neural
/// accelerator kernels.
private let swiftLMMetallibCMakeFlags = [
  "-DMLX_BUILD_TESTS=OFF",
  "-DMLX_BUILD_EXAMPLES=OFF",
  "-DMLX_BUILD_BENCHMARKS=OFF",
  "-DMLX_BUILD_PYTHON_BINDINGS=OFF",
  "-DMLX_METAL_JIT=OFF",
  "-DMLX_ENABLE_NAX=1",
  "-DCMAKE_BUILD_TYPE=Release",
]

// MARK: - Package.resolved decoding

/// The subset of `Package.resolved` needed to read a pinned dependency's
/// resolved commit.
private struct ResolvedPackages: Decodable {
  struct Pin: Decodable {
    struct State: Decodable {
      let revision: String?
    }

    let identity: String
    let state: State
  }

  let pins: [Pin]
}

// MARK: - SwiftLM chat binary

extension DevTool {
  /// Build SwiftLM's chat server binary and its Metal shader library, staged into
  /// `Products/Build/<configuration>/swiftlm/` for install and release.
  ///
  /// SwiftLM's OpenAI chat server lives in an executable target, so lmd runs the
  /// prebuilt binary rather than compiling chat in-process (see AGENTS.md 3.1).
  /// This drives SwiftLM's own build in Swift, mirroring its CI recipe, against
  /// lmd's resolved MLX commits so the chat binary uses the same MLX as lmd's
  /// embedding and video paths. The heavy build always targets Release and is
  /// guarded by a stamp; only the cheap staging copy runs per configuration.
  func buildSwiftLM(configuration: String) throws {
    Output.debug("buildSwiftLM configuration=\(configuration)")
    let swiftLMDirectory = repoRoot.appendingPathComponent("SwiftLM")
    guard fileManager.fileExists(atPath: swiftLMDirectory.path) else {
      throw ToolError.failure("SwiftLM submodule missing at \(swiftLMDirectory.path)")
    }

    try initializeSwiftLMSubmodule()
    let mlxCommits = try resolvedMLXCommits()
    try pinSwiftLMMLXSubmodules(in: swiftLMDirectory, to: mlxCommits)

    let stampInputs = try swiftLMStampInputs(
      swiftLMDirectory: swiftLMDirectory, mlxCommits: mlxCommits)
    let releaseDirectory = swiftLMReleaseDirectory(swiftLMDirectory)
    let builtBinary = releaseDirectory.appendingPathComponent(swiftLMBinaryName)
    let builtMetallib = releaseDirectory.appendingPathComponent("default.metallib")
    let alreadyBuilt =
      fileManager.isExecutableFile(atPath: builtBinary.path)
      && fileManager.fileExists(atPath: builtMetallib.path)
      && currentSwiftLMStamp() == stampInputs

    let didHeavyBuild = !alreadyBuilt
    if alreadyBuilt {
      try writeLine("  swiftlm: build up to date")
    } else {
      try ensureCMake()
      try ensureMetalToolchainForSwiftLM()
      try compileSwiftLMBinary(in: swiftLMDirectory)
      try compileSwiftLMMetallib(in: swiftLMDirectory)
      try writeSwiftLMStamp(stampInputs)
    }

    try buildSwiftLMNaxMetallibs(in: swiftLMDirectory, rebuild: didHeavyBuild)

    try stageSwiftLMArtifacts(
      from: swiftLMDirectory, into: swiftLMStagingDirectory(configuration: configuration))
  }
}

// MARK: - Submodule and MLX coherence

extension DevTool {
  /// Path to the staged SwiftLM artifacts under the configuration's build
  /// directory. A subdirectory keeps SwiftLM's `default.metallib` from colliding
  /// with lmd's own `default.metallib` staged beside its binaries.
  func swiftLMStagingDirectory(configuration: String) -> URL {
    buildDirectory(configuration: configuration).appendingPathComponent("swiftlm")
  }

  /// SwiftLM's SwiftPM Release product directory, where the chat binary and the
  /// colocated metallib live.
  private func swiftLMReleaseDirectory(_ swiftLMDirectory: URL) -> URL {
    swiftLMDirectory.appendingPathComponent(".build/arm64-apple-macosx/release")
  }

  /// Initialize the SwiftLM submodule and its nested MLX submodules, so a
  /// checkout that skipped `--recurse-submodules` still builds.
  private func initializeSwiftLMSubmodule() throws {
    Output.debug("initializeSwiftLMSubmodule")
    let arguments = ["submodule", "update", "--init", "--recursive", "SwiftLM"]
    try runPassthrough("git", arguments, currentDirectory: repoRoot)
  }

  /// Read lmd's resolved `mlx-swift` and `mlx-swift-lm` commits from
  /// `Package.resolved`. These pin SwiftLM's MLX to lmd's exact MLX.
  private func resolvedMLXCommits() throws -> [String: String] {
    let resolvedURL = repoRoot.appendingPathComponent("Package.resolved")
    let data = try Data(contentsOf: resolvedURL)
    let resolved = try JSONDecoder().decode(ResolvedPackages.self, from: data)
    var commits: [String: String] = [:]
    for name in coherentMLXSubmoduleNames {
      guard let pin = resolved.pins.first(where: { $0.identity == name }),
        let revision = pin.state.revision
      else {
        throw ToolError.failure("Package.resolved has no resolved revision for \(name)")
      }
      commits[name] = revision
    }
    return commits
  }

  /// Check out SwiftLM's MLX submodules to lmd's resolved commits. Fetches first
  /// in case the commit is not yet present locally, then checks it out detached.
  private func pinSwiftLMMLXSubmodules(in swiftLMDirectory: URL, to commits: [String: String])
    throws
  {
    for name in coherentMLXSubmoduleNames {
      guard let commit = commits[name] else {
        continue
      }
      let submoduleDirectory = swiftLMDirectory.appendingPathComponent(name)
      if currentGitHead(in: submoduleDirectory) == commit {
        continue
      }
      let fetchArguments = ["-C", submoduleDirectory.path, "fetch", "--quiet", "origin"]
      do {
        _ = try runCaptured("git", fetchArguments)
      } catch {
        Output.notice("swiftlm: fetch \(name) failed, using local objects: \(error)")
      }
      let checkoutArguments = [
        "-C", submoduleDirectory.path, "checkout", "--quiet", "--detach", commit,
      ]
      try runPassthrough("git", checkoutArguments)
      try writeLine("  swiftlm: pinned \(name) to \(commit.prefix(shortCommitLength))")
    }
  }

  /// The current `HEAD` commit of a git working tree, or nil when it cannot be
  /// read (for example an uninitialized submodule).
  private func currentGitHead(in directory: URL) -> String? {
    do {
      let result = try runCaptured("git", ["-C", directory.path, "rev-parse", "HEAD"])
      return result.output.trimmingCharacters(in: .whitespacesAndNewlines)
    } catch {
      return nil
    }
  }
}

// MARK: - Build steps

extension DevTool {
  /// Ensure the on-demand Metal toolchain is available. Best-effort through
  /// swift-mk (the same call lmd's metallib path uses), which is on PATH when the
  /// build generate hook runs under `make`. Standalone runs may lack swift-mk, so
  /// fall back to requiring that `metal` is already reachable and error clearly if
  /// not.
  private func ensureMetalToolchainForSwiftLM() throws {
    Output.debug("ensureMetalToolchainForSwiftLM")
    do {
      try runSwiftMk(["toolchain", "download-component", "MetalToolchain"])
    } catch {
      Output.warning("swiftlm: metal toolchain download via swift-mk unavailable: \(error)")
      guard isMetalCompilerReachable() else {
        throw ToolError.failure(
          "Metal toolchain unavailable; run `xcodebuild -downloadComponent MetalToolchain`")
      }
    }
  }

  /// Whether the Metal shader compiler is reachable through `xcrun`.
  private func isMetalCompilerReachable() -> Bool {
    do {
      _ = try runCaptured("xcrun", ["--find", "metal"])
      return true
    } catch {
      return false
    }
  }

  /// Install cmake through Homebrew when it is not already on PATH. cmake drives
  /// the Metal shader library build; SwiftLM's CI assumes it is present.
  private func ensureCMake() throws {
    Output.debug("ensureCMake")
    do {
      _ = try runCaptured("which", [cmakeCommand])
      return
    } catch {
      Output.notice("swiftlm: cmake not on PATH: \(error)")
    }
    try writeLine("  swiftlm: cmake not found, installing via Homebrew")
    try runPassthrough("brew", ["install", cmakeCommand])
  }

  /// Compile SwiftLM's chat server binary in Release. The binary is a runtime
  /// dependency, so it is always built optimized regardless of lmd's build
  /// configuration.
  private func compileSwiftLMBinary(in swiftLMDirectory: URL) throws {
    Output.debug("compileSwiftLMBinary")
    let arguments = ["build", "-c", "release", "--product", swiftLMBinaryName]
    try runPassthrough(swiftCommand, arguments, currentDirectory: swiftLMDirectory)
  }

  /// Build the AOT NAX metallibs from SwiftLM's own mlx-swift kernels into a
  /// `nax/` directory beside the chat binary, so the SwiftLM child loads the
  /// correctly compiled bf16 NAX GEMM kernels instead of JIT-compiling them,
  /// which the macOS 26.5 Metal compiler miscompiles (see PR #6 and AGENTS.md
  /// 3.1). Built from SwiftLM's own source so the kernels always match the MLX
  /// the chat binary links, independent of lmd's in-process `Derived/nax`. Skips
  /// when the metallibs already exist and no heavy rebuild ran.
  private func buildSwiftLMNaxMetallibs(in swiftLMDirectory: URL, rebuild: Bool) throws {
    Output.debug("buildSwiftLMNaxMetallibs rebuild=\(rebuild)")
    let kernelsDirectory = swiftLMDirectory.appendingPathComponent(
      "mlx-swift/Source/Cmlx/mlx/mlx/backend/metal/kernels")
    let probe = kernelsDirectory.appendingPathComponent(
      "steel/gemm/kernels/steel_gemm_fused_nax.metal")
    let naxOutput = swiftLMReleaseDirectory(swiftLMDirectory).appendingPathComponent("nax")
    guard fileManager.fileExists(atPath: probe.path) else {
      // Remove any nax/ from a prior SwiftLM/MLX revision so stageSwiftLMArtifacts
      // does not stage stale kernels; without live source the chat child JITs,
      // matching the log line.
      try removeIfExists(naxOutput)
      try writeLine("  swiftlm: nax kernel source not found, chat will JIT")
      return
    }
    if !rebuild, swiftLMNaxMetallibsPresent(in: naxOutput) {
      try writeLine("  swiftlm: nax metallibs up to date")
      return
    }
    let built = try buildNaxMetallibs(kernelsDirectory: kernelsDirectory, into: naxOutput)
    try writeLine("  swiftlm: built \(built) nax metallib(s)")
  }

  /// Whether the SwiftLM NAX output holds at least the fused and split-K GEMM
  /// metallibs the bf16 chat path loads.
  private func swiftLMNaxMetallibsPresent(in naxOutput: URL) -> Bool {
    let required = ["steel_gemm_fused_nax.metallib", "steel_gemm_splitk_nax.metallib"]
    return required.allSatisfy { name in
      fileManager.fileExists(atPath: naxOutput.appendingPathComponent(name).path)
    }
  }

  /// Compile SwiftLM's Metal shader library with cmake, mirroring SwiftLM's CI,
  /// then colocate it as `default.metallib` beside the binary where the mlx
  /// loader resolves it.
  private func compileSwiftLMMetallib(in swiftLMDirectory: URL) throws {
    Output.debug("compileSwiftLMMetallib")
    let metallibBuildDirectory = swiftLMDirectory.appendingPathComponent(".build/metallib_build")
    try removeIfExists(metallibBuildDirectory)
    try fileManager.createDirectory(at: metallibBuildDirectory, withIntermediateDirectories: true)

    let mlxSource = swiftLMDirectory.appendingPathComponent("mlx-swift/Source/Cmlx/mlx")
    guard fileManager.fileExists(atPath: mlxSource.path) else {
      throw ToolError.failure("SwiftLM mlx-swift submodule source missing at \(mlxSource.path)")
    }
    let cmakeArguments = [mlxSource.path] + swiftLMMetallibCMakeFlags
    try runPassthrough(cmakeCommand, cmakeArguments, currentDirectory: metallibBuildDirectory)
    let processorCount = ProcessInfo.processInfo.activeProcessorCount
    let makeArguments = ["mlx-metallib", "-j\(processorCount)"]
    try runPassthrough(makeCommand, makeArguments, currentDirectory: metallibBuildDirectory)

    guard let builtMetallib = findFile(named: "mlx.metallib", under: metallibBuildDirectory) else {
      throw ToolError.failure(
        "metallib build produced no mlx.metallib under \(metallibBuildDirectory.path)")
    }
    let releaseDirectory = swiftLMReleaseDirectory(swiftLMDirectory)
    try fileManager.createDirectory(at: releaseDirectory, withIntermediateDirectories: true)
    try copyReplacingItem(
      at: builtMetallib, to: releaseDirectory.appendingPathComponent("default.metallib"))
  }

  /// Copy the built SwiftLM binary and its `default.metallib` into the staging
  /// subdirectory install and release read from.
  private func stageSwiftLMArtifacts(from swiftLMDirectory: URL, into staging: URL) throws {
    Output.debug("stageSwiftLMArtifacts staging=\(staging.path)")
    try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
    let releaseDirectory = swiftLMReleaseDirectory(swiftLMDirectory)
    for name in [swiftLMBinaryName, "default.metallib"] {
      let source = releaseDirectory.appendingPathComponent(name)
      guard fileManager.fileExists(atPath: source.path) else {
        throw ToolError.failure("SwiftLM build did not produce \(source.path)")
      }
      try copyReplacingItem(at: source, to: staging.appendingPathComponent(name))
      try writeLine("  staged swiftlm/\(name)")
    }
    // Stage the AOT NAX metallibs beside the binary so the chat child's
    // `current_binary_dir/nax` lookup resolves them instead of JIT-compiling.
    let naxSource = releaseDirectory.appendingPathComponent("nax")
    if fileManager.fileExists(atPath: naxSource.path) {
      try copyReplacingItem(at: naxSource, to: staging.appendingPathComponent("nax"))
      try writeLine("  staged swiftlm/nax")
    }
  }

  /// Recursively find the first file with `name` under `directory`, or nil.
  private func findFile(named name: String, under directory: URL) -> URL? {
    guard let enumerator = fileManager.enumerator(at: directory, includingPropertiesForKeys: nil)
    else {
      return nil
    }
    for case let item as URL in enumerator where item.lastPathComponent == name {
      return item
    }
    return nil
  }
}

// MARK: - Build stamp

extension DevTool {
  /// The rebuild key: the SwiftLM gitlink commit plus lmd's two resolved MLX
  /// commits. Any of these changing forces a SwiftLM rebuild.
  private func swiftLMStampInputs(swiftLMDirectory: URL, mlxCommits: [String: String]) throws
    -> String
  {
    let gitlink = try runCaptured("git", ["-C", swiftLMDirectory.path, "rev-parse", "HEAD"])
      .output.trimmingCharacters(in: .whitespacesAndNewlines)
    var lines = ["swiftlm=\(gitlink)"]
    for name in coherentMLXSubmoduleNames {
      lines.append("\(name)=\(mlxCommits[name] ?? "")")
    }
    return lines.joined(separator: "\n") + "\n"
  }

  private func swiftLMStampURL() -> URL {
    productsDirectory().appendingPathComponent(".swiftlm-built-sha")
  }

  private func currentSwiftLMStamp() -> String? {
    do {
      return try String(contentsOf: swiftLMStampURL(), encoding: .utf8)
    } catch {
      return nil
    }
  }

  private func writeSwiftLMStamp(_ inputs: String) throws {
    Output.debug("writeSwiftLMStamp")
    try fileManager.createDirectory(at: productsDirectory(), withIntermediateDirectories: true)
    try inputs.write(to: swiftLMStampURL(), atomically: true, encoding: .utf8)
  }
}
