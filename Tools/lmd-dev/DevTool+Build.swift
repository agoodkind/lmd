//
//  DevTool+Build.swift
//  lmd-dev
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-05-10.
//  Copyright © 2026, all rights reserved.
//

import Foundation
import SwiftMkCore

// MARK: - Build

extension DevTool {
  /// Build every product binary plus the MLX Metal shader library.
  ///
  /// The build is split across two systems because neither alone produces a
  /// usable artifact on macOS:
  ///
  /// - SwiftPM (`swift build`) links `swift-nio` with the resilient layout
  ///   the Swift runtime expects, but cannot compile `.metal` shaders.
  /// - xcodebuild (via Tuist) compiles `.metal` into `default.metallib`, but
  ///   the resulting executables link `swift-nio`'s `ManagedAtomic<Bool>`
  ///   without the required type metadata. The first socket allocation
  ///   inside `BaseSocketChannel.init(...)` then crashes with
  ///   `EXC_BAD_ACCESS` in `swift_allocObject`.
  ///
  /// Upstream context:
  /// - https://github.com/ml-explore/mlx-swift/issues/345 (metallib packaging)
  /// - https://github.com/ml-explore/mlx-swift/issues/36 (SwiftPM cannot compile Metal)
  /// - https://github.com/vapor/vapor/issues/3369 (Tuist/swift-nio linkage bug)
  ///
  /// `stageBuildArtifacts` collects outputs from both systems into a single
  /// staging directory under `Products/Build/<configuration>/`. `install`
  /// reads exclusively from that staging directory and does not need to know
  /// about either build system.
  func build(configuration: String) throws {
    // Build the vendored SwiftLM chat binary first, as part of the build rather
    // than a generate hook, so the lint and audit gates (which do not build) never
    // clone or compile it.
    try buildSwiftLM(configuration: configuration)
    // Under `make` (or any live swift-mk gate ancestor), the existing GateProof
    // guards in the SwiftPM build steps authorize the compile, so run the build
    // directly. With no such ancestor (a direct `lmd-dev build`), run swift-mk's
    // hard lint gate in-process through GatedBuild.run and compile under the minted
    // receipt instead, so a decoupled build still gates without a make ancestor.
    if GateProof.isCurrentlyGated() {
      try buildSwiftPackage(configuration: configuration)
      try buildMetallib(configuration: configuration)
      try buildNaxAotLibraries(configuration: configuration)
      try stageBuildArtifacts(products: productBinaries, configuration: configuration)
    } else {
      try buildDecoupled(configuration: configuration)
    }
  }

  /// Build with no `make`/`swift-mk` ancestor by running swift-mk's hard lint gate
  /// in-process, then compiling under the receipt the gate mints. lmd declares no
  /// generate, dead-code coverage, or log-audit command in its Makefile, so the gate
  /// runs with no hooks and its dead-code step is the package periphery scan; lmd
  /// signing is post-build codesign, not an xcconfig override, so no signing options
  /// are passed. The compile closure runs the same SwiftPM and metallib steps the
  /// gated path runs, minus the per-step GateProof guards since the gate has already
  /// passed in this process.
  private func buildDecoupled(configuration: String) throws {
    let request = GatedBuild.Request(entry: "lmd build \(configuration)") { receipt in
      do {
        try self.buildSwiftPackageWithoutGate(configuration: configuration, receipt: receipt)
        try self.buildMetallib(configuration: configuration, receipt: receipt)
        try self.buildNaxAotLibraries(configuration: configuration)
        try self.stageBuildArtifacts(
          products: productBinaries, configuration: configuration)
        return 0
      } catch {
        Output.error("lmd decoupled compile failed: \(error)")
        return 1
      }
    }
    let status = GatedBuild.run(request)
    guard status == 0 else {
      throw ToolError.failure("gated build failed (status \(status))")
    }
  }

  /// The SwiftPM build of every product without the GateProof guard, for the
  /// decoupled path where `GatedBuild.run` has already run the hard gate in-process
  /// and minted the receipt that authorizes this compile.
  private func buildSwiftPackageWithoutGate(configuration: String, receipt: GateReceipt) throws {
    Output.debug("buildSwiftPackageWithoutGate configuration=\(configuration)")
    let status = SwiftPM.build(
      swiftPackageRequest(configuration: configuration), receipt: receipt)
    guard status == 0 else {
      throw ToolError.failure("swift build failed (status \(status))")
    }
  }

  /// The SwiftPM request that routes a `swift build`/`swift test` through swift-mk's
  /// `SwiftPM` chokepoint, so the build takes the per-worktree build lock (the same
  /// `Tools/.build` two builds in one worktree otherwise collide on) and inherits the
  /// shared SwiftPM cache flags the engine injects via `SWIFT_MK_SWIFTPM_CACHE_ARGS`.
  private func swiftPackageRequest(
    configuration: String,
    product: String? = nil,
    environment: [String: String] = [:]
  ) -> SwiftPM.Request {
    let resolved: SwiftPM.Configuration =
      configuration.lowercased() == "release" ? .release : .debug
    return SwiftPM.Request(
      configuration: resolved, product: product, environment: environment)
  }

  /// Build a single product binary plus the metallib. Used by smoke targets
  /// that only need `lmd-serve`. Same hybrid rationale as `build`.
  func buildProduct(_ product: String, configuration: String) throws {
    try buildSwiftPackageProduct(product, configuration: configuration)
    try buildMetallib(configuration: configuration)
    try buildNaxAotLibraries(configuration: configuration)
    try stageBuildArtifacts(products: [product], configuration: configuration)
  }

  /// SwiftPM build of every product. Outputs land at
  /// `.build/<configuration>/<product>` (configuration is lower-cased per
  /// SwiftPM's convention: `debug`, `release`).
  func buildSwiftPackage(configuration: String) throws {
    Output.debug("buildSwiftPackage configuration=\(configuration)")
    let status = SwiftPM.build(swiftPackageRequest(configuration: configuration))
    guard status == 0 else {
      throw ToolError.failure("swift build failed (status \(status))")
    }
  }

  /// SwiftPM build of one product. Faster than `buildSwiftPackage` when the
  /// caller only needs a single binary.
  func buildSwiftPackageProduct(_ product: String, configuration: String) throws {
    Output.debug("buildSwiftPackageProduct product=\(product) configuration=\(configuration)")
    let status = SwiftPM.build(
      swiftPackageRequest(configuration: configuration, product: product))
    guard status == 0 else {
      throw ToolError.failure("swift build failed (status \(status))")
    }
  }

  /// Copy SwiftPM binaries and the Xcode-built metallib into the single
  /// staging directory at `Products/Build/<configuration>/`.
  ///
  /// Both halves of the hybrid build write here so `install` can read from
  /// one location. Throws if SwiftPM did not produce an expected binary.
  /// The failure message names the missing path so the operator can run
  /// `swift build` standalone to surface the underlying compile error.
  func stageBuildArtifacts(products: [String], configuration: String) throws {
    Output.debug("stageBuildArtifacts configuration=\(configuration)")
    let staging = buildDirectory(configuration: configuration)
    try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
    let swiftBuild = swiftPackageBuildDirectory(configuration: configuration)
    for product in products {
      let source = swiftBuild.appendingPathComponent(product)
      guard fileManager.isExecutableFile(atPath: source.path) else {
        throw ToolError.failure("SwiftPM did not produce \(source.path)")
      }
      try copyReplacingItem(at: source, to: staging.appendingPathComponent(product))
      try writeLine("  staged \(product)")
    }
    try stageCompatibilityLinks(in: staging)
    try stageRuntimeResources(for: configuration)
  }
}

// MARK: - Test

extension DevTool {
  /// Stage the metallib next to the SwiftPM test runners between `--build-tests` and the
  /// test run. Returns false to fail the test gate rather than throwing out of the
  /// `@Sendable` afterBuildTests closure the SwiftPM chokepoint holds one build lock
  /// across.
  private func stageMetallibBetweenBuildAndTest(configuration: String) -> Bool {
    do {
      try stageMetallibForSwiftTest(configuration: configuration)
      return true
    } catch {
      Output.error("staging metallib for swift test failed: \(error)")
      return false
    }
  }

  func test() throws {
    Output.debug("test")
    // Fail fast and clearly when invoked without a swift-mk gate ancestor, before the
    // metallib build below shells `swift-mk toolchain build` and fails opaquely.
    if let status = GateProof.refusal(entry: "lmd build") {
      throw ToolError.failure("gate proof refused (status \(status))")
    }
    // Run the suite via SwiftPM instead of `tuist test`. Tuist's static-framework
    // SPM integration fails to propagate internal C-target module maps (EventSource
    // -> async-http-client / swift-nio / _NumericsShims) on Xcode 26, which breaks
    // only the static-framework test build; the SwiftPM executable build is fine,
    // so `swift test` sidesteps it. The static base is required by the Swift Macro
    // targets, so it cannot be flipped. swift-mk's SWIFT_TEST_MODE=spm is the
    // framework-owned form of this once LMD routes through swift-mk.
    //
    // SwiftPM cannot compile the Metal shaders, so it never produces mlx-swift's
    // metallib and an MLX test crashes with "Failed to load the default metallib".
    // The metallib is built by xcodebuild (the same step the product build uses),
    // then colocated next to the test runner where mlx's loader looks first, between
    // `--build-tests` and the `--skip-build` test run inside the chokepoint's held lock.
    let configuration = "Debug"
    try buildMetallib(configuration: configuration)
    let request = SwiftPM.TestRequest(
      package: swiftPackageRequest(
        configuration: configuration,
        environment: ["LMD_BINARY_DIR": releaseBuildDirectory().path]),
      buildTests: true,
      skipBuild: true
    ) { [self] in
      stageMetallibBetweenBuildAndTest(configuration: configuration)
    }
    let status = SwiftPM.test(request)
    guard status == 0 else {
      throw ToolError.failure("swift test failed (status \(status))")
    }
  }

  /// Run the integration suite against the isolated launchd test daemon.
  ///
  /// The plain `test` target skips the broker-backed integration tests so the
  /// unit run stays headless. This target builds the product binaries, brings up
  /// the isolated `test-daemon` (an isolated daemon on :5401 with `.test` Mach
  /// services and its own data dir, so production on :5400 is never touched),
  /// points the tests at it via `LMD_TEST_BASE_URL` and `LMD_CONTROL_SERVICE`,
  /// runs them, then tears the daemon down whatever the outcome.
  func testIntegration() throws {
    Output.debug("testIntegration")
    let configuration = "Debug"
    try build(configuration: configuration)
    // The product binaries the daemon runs are built above, so bring the isolated
    // :5401 daemon up before the test-build below and tear it down whatever the
    // outcome. The metallib is staged next to the test runners between `--build-tests`
    // and the `--skip-build` run inside the chokepoint's held lock.
    try testDaemonUp()
    defer { teardownTestDaemonAfterIntegration() }
    let environment: [String: String] = [
      "LMD_BINARY_DIR": releaseBuildDirectory().path,
      "LMD_INTEGRATION": "1",
      "LMD_XPC_USE_LAUNCHD_DAEMON": "1",
      "LMD_CONTROL_SERVICE": "io.goodkind.lmd.control.test",
      "LMD_TEST_BASE_URL": "http://localhost:5401",
    ]
    let request = SwiftPM.TestRequest(
      package: swiftPackageRequest(configuration: configuration, environment: environment),
      buildTests: true,
      skipBuild: true,
      filter: "IntegrationTests.(EmbeddingsRouteTests|XPCBrokerTests|HostSpawnTests)"
    ) { [self] in
      stageMetallibBetweenBuildAndTest(configuration: configuration)
    }
    let status = SwiftPM.test(request)
    guard status == 0 else {
      throw ToolError.failure("swift test failed (status \(status))")
    }
  }

  /// Best-effort teardown of the isolated test daemon after the integration run,
  /// logging rather than throwing so the integration result is what surfaces.
  private func teardownTestDaemonAfterIntegration() {
    do {
      try testDaemonDown()
    } catch {
      Output.warning("test daemon teardown failed error=\(error)")
    }
  }

  func snapshotUpdate() throws {
    Output.debug("snapshotUpdate")
    // Fail fast and clearly when invoked without a swift-mk gate ancestor, before the
    // metallib build below shells `swift-mk toolchain build` and fails opaquely.
    if let status = GateProof.refusal(entry: "lmd build") {
      throw ToolError.failure("gate proof refused (status \(status))")
    }
    // Same SwiftPM path as `test()`: `tuist test` breaks on Xcode 26's static-framework
    // SPM integration, and SwiftLMTUITests is a SwiftPM test target, so the snapshots
    // update via `swift test --filter` with SNAPSHOT_UPDATE=1. The metallib is built and
    // colocated first, the same as the regular test run.
    let configuration = "Debug"
    try buildMetallib(configuration: configuration)
    let request = SwiftPM.TestRequest(
      package: swiftPackageRequest(
        configuration: configuration,
        environment: [
          "LMD_BINARY_DIR": releaseBuildDirectory().path,
          "SNAPSHOT_UPDATE": "1",
        ]),
      buildTests: true,
      skipBuild: true,
      filter: "SwiftLMTUITests"
    ) { [self] in
      stageMetallibBetweenBuildAndTest(configuration: configuration)
    }
    let status = SwiftPM.test(request)
    guard status == 0 else {
      throw ToolError.failure("swift test failed (status \(status))")
    }
  }
}

// MARK: - Install

extension DevTool {
  func clean() throws {
    for path in [
      ".build",
      "Derived",
      "LMD.xcodeproj",
      "LMD.xcworkspace",
      "lmd.xcodeproj",
      "lmd.xcworkspace",
      "Tuist/.build",
      "Products/Build",
    ] {
      try removeIfExists(repoRoot.appendingPathComponent(path))
    }
  }

  func install(configuration: String) throws {
    Output.debug("install configuration=\(configuration)")
    try build(configuration: configuration)
    let sourceDirectory = buildDirectory(configuration: configuration)
    let binDirectory = prefixDirectory().appendingPathComponent("bin")
    try fileManager.createDirectory(at: binDirectory, withIntermediateDirectories: true)

    for binary in productBinaries {
      let source = sourceDirectory.appendingPathComponent(binary)
      let destination = binDirectory.appendingPathComponent(binary)
      try copyReplacingItem(at: source, to: destination)
      try writeLine("  installed \(destination.path)")
    }
    try stageCompatibilityLinks(in: binDirectory)

    try copyRuntimeResources(from: sourceDirectory, to: binDirectory)

    // Bundle the SwiftLM chat binary and its metallib into a swiftlm/ subdirectory
    // so its default.metallib does not collide with lmd's own beside the binaries.
    let swiftLMBinaryPath = try installSwiftLM(from: sourceDirectory, to: binDirectory)

    let agentDirectory = homeDirectory().appendingPathComponent("Library/LaunchAgents")
    try fileManager.createDirectory(at: agentDirectory, withIntermediateDirectories: true)
    let templateURL = repoRoot.appendingPathComponent("deploy/io.goodkind.lmd.serve.plist.example")
    let template = try String(contentsOf: templateURL, encoding: .utf8)
    let servePath = binDirectory.appendingPathComponent("lmd-serve").path
    let rendered =
      template
      .replacingOccurrences(of: "{{LMD_SERVE_PATH}}", with: servePath)
      .replacingOccurrences(of: "{{LMD_SWIFTLM_BINARY_PATH}}", with: swiftLMBinaryPath)
    try rendered.write(to: agentPlistURL(), atomically: true, encoding: .utf8)
    try writeLine("  wrote \(agentPlistURL().path)")
    try startServe()
  }

  /// Copy the staged SwiftLM binary and its metallib into `<bin>/swiftlm/` and
  /// return the installed binary path for the plist's `LMD_SWIFTLM_BINARY`.
  func installSwiftLM(from sourceDirectory: URL, to binDirectory: URL) throws -> String {
    Output.debug("installSwiftLM")
    let staged = sourceDirectory.appendingPathComponent("swiftlm")
    guard fileManager.fileExists(atPath: staged.path) else {
      throw ToolError.failure("SwiftLM was not staged at \(staged.path); run build first")
    }
    let destination = binDirectory.appendingPathComponent("swiftlm")
    try copyReplacingItem(at: staged, to: destination)
    let binary = destination.appendingPathComponent("SwiftLM")
    try writeLine("  installed \(binary.path)")
    return binary.path
  }

  func uninstall() throws {
    Output.debug("uninstall")
    do {
      try stopServe()
    } catch {
      Output.warning("uninstall stopServe failed error=\(error)")
    }
    try removeIfExists(agentPlistURL())

    let binDirectory = prefixDirectory().appendingPathComponent("bin")
    try removeIfExists(binDirectory.appendingPathComponent("swiftlm"))
    for binary in productBinaries + Array(compatibilityCommandLinks.keys) {
      let path = binDirectory.appendingPathComponent(binary)
      if fileManager.fileExists(atPath: path.path) {
        try fileManager.removeItem(at: path)
        try writeLine("  removed \(path.path)")
      }
    }
    for resourceName in ["mlx.metallib", "default.metallib", "mlx-swift_Cmlx.bundle"] {
      let path = binDirectory.appendingPathComponent(resourceName)
      if fileManager.fileExists(atPath: path.path) {
        try fileManager.removeItem(at: path)
        try writeLine("  removed \(path.path)")
      }
    }
  }

  func runBuiltBinary(_ name: String) throws {
    try build(configuration: "Release")
    try runPassthrough(releaseBuildDirectory().appendingPathComponent(name).path, [])
  }

  func runBuiltCommand(_ arguments: [String]) throws {
    try build(configuration: "Release")
    try runPassthrough(releaseBuildDirectory().appendingPathComponent("lmd").path, arguments)
  }
}

// MARK: - Runtime resources

extension DevTool {
  func stageRuntimeResources(for configuration: String) throws {
    Output.debug("stageRuntimeResources configuration=\(configuration)")
    let destination = buildDirectory(configuration: configuration)
    let resourceNames = ["mlx.metallib", "default.metallib", "mlx-swift_Cmlx.bundle"]
    var copied = Set<String>()
    for searchRoot in runtimeResourceSearchRoots(configuration: configuration) {
      guard fileManager.fileExists(atPath: searchRoot.path) else {
        continue
      }
      guard let enumerator = fileManager.enumerator(at: searchRoot, includingPropertiesForKeys: nil)
      else {
        continue
      }
      for case let item as URL in enumerator {
        guard resourceNames.contains(item.lastPathComponent) else {
          continue
        }
        guard !copied.contains(item.lastPathComponent) else {
          continue
        }
        try copyReplacingItem(
          at: item, to: destination.appendingPathComponent(item.lastPathComponent))
        copied.insert(item.lastPathComponent)
        try writeLine("  staged \(item.lastPathComponent)")
      }
    }
    try stageNaxLibraries(from: naxLibraryDirectory(), to: destination)
  }

  /// Copy the ahead-of-time-compiled NAX metallibs from `sourceNaxDirectory` into
  /// `<destinationParent>/nax/`, beside the binary or bundle that resolves them
  /// via `current_binary_dir()/nax`. No-op when no NAX libraries are present.
  func stageNaxLibraries(from sourceNaxDirectory: URL, to destinationParent: URL) throws {
    Output.debug("stageNaxLibraries source=\(sourceNaxDirectory.path)")
    guard fileManager.fileExists(atPath: sourceNaxDirectory.path) else {
      return
    }
    let entries = try fileManager.contentsOfDirectory(
      at: sourceNaxDirectory, includingPropertiesForKeys: nil)
    let metallibs = entries.filter { $0.pathExtension == "metallib" }
    guard !metallibs.isEmpty else {
      return
    }
    let destination = destinationParent.appendingPathComponent("nax")
    try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
    for library in metallibs {
      try copyReplacingItem(
        at: library, to: destination.appendingPathComponent(library.lastPathComponent))
    }
    try writeLine("  staged nax/ (\(metallibs.count) metallib) -> \(destination.path)")
  }

  private func runtimeResourceSearchRoots(configuration: String) -> [URL] {
    let derivedProducts = derivedProductsDirectory(configuration: configuration)
    let derived = repoRoot.appendingPathComponent("Derived")
    let xcodeDerived = homeDirectory().appendingPathComponent("Library/Developer/Xcode/DerivedData")
    return [derivedProducts, derived, xcodeDerived]
  }

  func copyRuntimeResources(from sourceDirectory: URL, to destinationDirectory: URL) throws {
    Output.debug("copyRuntimeResources source=\(sourceDirectory.path)")
    for resourceName in ["mlx.metallib", "default.metallib", "mlx-swift_Cmlx.bundle"] {
      let source = sourceDirectory.appendingPathComponent(resourceName)
      if fileManager.fileExists(atPath: source.path) {
        try copyReplacingItem(
          at: source, to: destinationDirectory.appendingPathComponent(resourceName))
        try writeLine(
          "  installed \(destinationDirectory.appendingPathComponent(resourceName).path)")
      }
    }
    try stageNaxLibraries(
      from: sourceDirectory.appendingPathComponent("nax"), to: destinationDirectory)
  }
}
