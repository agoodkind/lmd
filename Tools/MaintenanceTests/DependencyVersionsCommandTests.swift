//
//  DependencyVersionsCommandTests.swift
//  MaintenanceTests
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-10-25.
//  Copyright © 2026, all rights reserved.
//

import Foundation
import Nimble
import SwiftMkCore
import XCTest

@testable import lmd_maintenance

// MARK: - Public command regression

final class DependencyVersionsCommandTests: XCTestCase {
  func testRealPreparationPreservesRuntimeAndRejectsChangedInputs() throws {
    let fixture = try DependencyVersionsFixture()
    addTeardownBlock { [directory = fixture.directory] in
      Output.debug("versions.fixture.remove path=\(directory.path)")
      try FileManager.default.removeItem(at: directory)
    }
    Output.debug("versions.test.prepare")
    let prepared = fixture.invoke("prepare-versions")
    try requireMaintenanceCondition(
      prepared.status == 0, "prepare-versions failed: \(prepared.combined)")
    let state = try fixture.state()
    let effective = state.effectiveLibrary
    expect(effective) != fixture.libraryRevision
    let archive = fixture.proof.appendingPathComponent("library-commit-object.txt")
    let archivedRevision = try fixture.git(
      fixture.library, ["hash-object", "-t", "commit", archive.path])
    expect(archivedRevision) == effective
    let changedPaths = try fixture.git(
      fixture.library, ["diff", "--name-only", fixture.libraryRevision, effective])
    expect(changedPaths) == "Package.swift"
    for path in ["", "Tools", "Tuist"] {
      let url = fixture.root.appendingPathComponent(path).appendingPathComponent("Package.resolved")
      let pins = try DependencyVersionsLock(url).pins
      for (identity, expected) in [
        ("mlx-swift", fixture.coreRevision), ("mlx-swift-lm", effective),
      ] {
        let pin = try XCTUnwrap(pins.first { $0.identity == identity })
        let revision = try XCTUnwrap(pin.state["revision"])
        expect(revision) == expected
      }
    }
    let runtime = fixture.root.appendingPathComponent("SwiftLM/Sources/Fixture/Value.swift")
    let originalRuntime = try Data(contentsOf: runtime)
    try Data("public let changed = true\n".utf8).write(to: runtime)
    let sourceFailure = fixture.invoke("verify-versions")
    expect(sourceFailure.status) == 1
    expect(sourceFailure.combined).to(contain("Unexpected tracked SwiftLM source change"))
    try originalRuntime.write(to: runtime)
    let rootLock = fixture.root.appendingPathComponent("Package.resolved")
    let originalLock = try Data(contentsOf: rootLock)
    var changedLock = try DependencyVersionsLock(rootLock)
    changedLock.pins.removeAll { $0.identity == "other-fixture" }
    let changedBytes = try JSONEncoder().encode(changedLock)
    try changedBytes.write(to: rootLock)
    let lockFailure = fixture.invoke("verify-versions")
    expect(lockFailure.status) == 1
    expect(lockFailure.combined).to(
      contain("Resolver changed dependencies outside the requested MLX versions"))
    let capturedLock = try Data(
      contentsOf: fixture.proof.appendingPathComponent("Package.resolved"))
    expect(capturedLock) == changedBytes
    for name in ["tools-Package.resolved", "tuist-Package.resolved", "swiftlm-Package.resolved"] {
      expect(try Data(contentsOf: fixture.proof.appendingPathComponent(name)).isEmpty) == false
    }
    try originalLock.write(to: rootLock)
    let valid = fixture.invoke("verify-versions")
    expect(valid.status).to(equal(0), description: valid.combined)
  }
}

// MARK: - Real Git and SwiftPM fixture

private final class DependencyVersionsFixture {
  let directory: URL
  let root: URL
  let core: URL
  let library: URL
  let proof: URL
  let binary: URL
  var environment = ProcessInfo.processInfo.environment
  var coreRevision = ""
  var libraryRevision = ""

  init() throws {
    directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "lmd-versions-" + UUID().uuidString)
    root = directory.appendingPathComponent("lmd")
    core = directory.appendingPathComponent("sources/mlx-swift")
    library = directory.appendingPathComponent("sources/mlx-swift-lm")
    proof = directory.appendingPathComponent("proof")
    binary = Bundle(for: DependencyVersionsCommandTests.self).bundleURL.deletingLastPathComponent()
      .appendingPathComponent("lmd-maintenance")
    try repository(core, manifest: leafManifest("CoreFixture"))
    let originalCore = try commit(core)
    try repository(
      library, manifest: manifest("LibraryFixture", core: originalCore, library: nil, other: nil))
    libraryRevision = try commit(library)
    let other = directory.appendingPathComponent("sources/other-fixture")
    try repository(other, manifest: leafManifest("OtherFixture"))
    let otherRevision = try commit(other)
    try git(other, ["update-ref", "refs/tags/1.0.0", otherRevision])
    let swiftLM = directory.appendingPathComponent("sources/SwiftLM")
    try repository(
      swiftLM,
      manifest: """
        // swift-tools-version: 6.2
        import PackageDescription
        let package = Package(name: "SwiftLMFixture", dependencies: [
          .package(path: "mlx-swift"), .package(path: "mlx-swift-lm"),
          .package(url: "\(other.absoluteString)", exact: "1.0.0")
        ], targets: [.target(name: "SwiftLMFixture", dependencies: [
          .product(name: "CoreFixture", package: "mlx-swift"),
          .product(name: "LibraryFixture", package: "mlx-swift-lm"),
          .product(name: "OtherFixture", package: "other-fixture")], path: "Sources/Fixture")])
        """)
    for (name, source) in [("mlx-swift", core), ("mlx-swift-lm", library)] {
      try git(swiftLM, ["-c", "protocol.file.allow=always", "submodule", "add", source.path, name])
    }
    configureFixtureMirrors()
    try run(swiftLM, "swift", ["package", "resolve"])
    let swiftLMRevision = try commit(swiftLM)
    let rootManifest = manifest(
      "ConsumerFixture", core: originalCore, library: libraryRevision, other: other)
    try repository(root, manifest: rootManifest)
    try writeAuxiliaryPackages(rootManifest: rootManifest)
    try git(
      root, ["-c", "protocol.file.allow=always", "submodule", "add", swiftLM.path, "SwiftLM"])
    try resolveRootPackages()
    let rootRevision = try commit(root)
    try write(core.appendingPathComponent("Sources/Fixture/Value.swift"), "public let value = 2\n")
    coreRevision = try commit(core, parent: originalCore)
    environment["LMD_REF"] = rootRevision
    environment["CORE_REF"] = coreRevision
    environment["LIBRARY_REF"] = libraryRevision
    environment["SWIFTLM_REF"] = swiftLMRevision
    let githubEnvironment = directory.appendingPathComponent("github-env.txt")
    try Data().write(to: githubEnvironment)
    environment["GITHUB_ENV"] = githubEnvironment.path
  }

  private func writeAuxiliaryPackages(rootManifest: String) throws {
    try write(root.appendingPathComponent("Tuist/Package.swift"), rootManifest)
    let toolsManifest = """
      // swift-tools-version: 6.2
      import PackageDescription
      let package = Package(name: "ToolsFixture", dependencies: [.package(path: "..")], targets: [
        .target(name: "ToolsFixture", dependencies: [
          .product(name: "ConsumerFixture", package: "lmd")
        ], path: "Sources/Fixture")
      ])
      """
    try write(root.appendingPathComponent("Tools/Package.swift"), toolsManifest)
    for path in ["Tools", "Tuist"] {
      try write(
        root.appendingPathComponent(path + "/Sources/Fixture/Value.swift"), "public let value = 1\n"
      )
    }
  }

  private func configureFixtureMirrors() {
    environment["GIT_CONFIG_COUNT"] = "3"
    environment["GIT_CONFIG_KEY_0"] = "protocol.file.allow"
    environment["GIT_CONFIG_VALUE_0"] = "always"
    environment["GIT_CONFIG_KEY_1"] = "url.\(core.absoluteString).insteadOf"
    environment["GIT_CONFIG_VALUE_1"] = "https://github.com/agoodkind/mlx-swift.git"
    environment["GIT_CONFIG_KEY_2"] = "url.\(library.absoluteString).insteadOf"
    environment["GIT_CONFIG_VALUE_2"] = "https://github.com/agoodkind/mlx-swift-lm.git"
  }

  private func resolveRootPackages() throws {
    for path in ["", "Tools", "Tuist"] {
      try run(
        root,
        "swift",
        ["package", "--package-path", root.appendingPathComponent(path).path, "resolve"])
    }
  }

  @discardableResult
  func run(_ path: URL, _ executable: String, _ arguments: [String]) throws -> String {
    Output.debug("versions.fixture.command executable=\(executable)")
    let result = Shell.run(
      "/usr/bin/env", ["-C", path.path, executable] + arguments, environment: environment)
    guard result.status == 0 else {
      throw NSError(domain: result.combined, code: Int(result.status))
    }
    return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  @discardableResult
  func git(_ path: URL, _ arguments: [String]) throws -> String { try run(path, "git", arguments) }

  func write(_ path: URL, _ text: String) throws {
    Output.debug("versions.fixture.write path=\(path.path)")
    try FileManager.default.createDirectory(
      at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(text.utf8).write(to: path)
  }

  func repository(_ path: URL, manifest: String) throws {
    Output.debug("versions.fixture.repository.create path=\(path.path)")
    try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
    try run(path, "git", ["init", "--quiet"])
    try write(path.appendingPathComponent("Package.swift"), manifest)
    try write(path.appendingPathComponent("Sources/Fixture/Value.swift"), "public let value = 1\n")
    try write(path.appendingPathComponent(".gitignore"), ".build/\n.make/\n")
  }

  func commit(_ path: URL, parent: String? = nil) throws -> String {
    try git(path, ["add", "."])
    let tree = try git(path, ["write-tree"])
    var arguments = [
      "-c", "user.name=CI versions fixture", "-c", "user.email=noreply@github.com", "commit-tree",
      tree,
    ]
    if let parent { arguments += ["-p", parent] }
    arguments += [
      "-m", "Create a real versions fixture\n\nCo-authored-by: Codex <noreply@openai.com>",
    ]
    let revision = try git(path, arguments)
    try git(path, ["update-ref", "HEAD", revision])
    return revision
  }

  func leafManifest(_ product: String) -> String {
    """
    // swift-tools-version: 6.2
    import PackageDescription
    let package = Package(name: "\(product)", products: [.library(name: "\(product)", targets: ["\(product)"])], targets: [.target(name: "\(product)", path: "Sources/Fixture")])
    """
  }

  func manifest(_ name: String, core: String, library: String?, other: URL?) -> String {
    var dependencies = [
      ".package(url: \"https://github.com/agoodkind/mlx-swift.git\", revision: \"\(core)\")"
    ]
    var products = [".product(name: \"CoreFixture\", package: \"mlx-swift\")"]
    if let library {
      dependencies.append(
        ".package(url: \"https://github.com/agoodkind/mlx-swift-lm.git\", revision: \"\(library)\")"
      )
      products.append(".product(name: \"LibraryFixture\", package: \"mlx-swift-lm\")")
    }
    if let other {
      dependencies.append(".package(url: \"\(other.absoluteString)\", exact: \"1.0.0\")")
      products.append(".product(name: \"OtherFixture\", package: \"other-fixture\")")
    }
    return """
      // swift-tools-version: 6.2
      import PackageDescription
      let package = Package(name: "\(name)", products: [.library(name: "\(name)", targets: ["\(name)"])], dependencies: [\(dependencies.joined(separator: ","))], targets: [.target(name: "\(name)", dependencies: [\(products.joined(separator: ","))], path: "Sources/Fixture")])
      """
  }

  func invoke(_ mode: String) -> Shell.Result {
    Shell.run(
      binary.path,
      [mode, root.path, core.path, library.path, proof.path],
      environment: environment)
  }

  func state() throws -> DependencyVersionsState {
    Output.debug("versions.fixture.state.read")
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    return try decoder.decode(
      DependencyVersionsState.self,
      from: Data(contentsOf: proof.appendingPathComponent("versions.json")))
  }
}
