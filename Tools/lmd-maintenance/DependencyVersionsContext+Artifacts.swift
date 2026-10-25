//
//  DependencyVersionsContext+Artifacts.swift
//  lmd-maintenance
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-10-25.
//  Copyright © 2026, all rights reserved.
//

import Foundation
import SwiftMkCore

// MARK: - Source shader records

struct DependencyVersionsShaderRecord: Encodable {
  let source: String
  let destination: String
  let sha256: String
}

// MARK: - DependencyVersionsShaderArchive

private final class DependencyVersionsShaderArchive {
  let context: DependencyVersionsContext
  let directory: URL
  var records: [DependencyVersionsShaderRecord] = []
  let names = [
    "steel_gemm_fused_nax", "steel_gemm_splitk_nax", "steel_gemm_gather_nax",
    "steel_gemm_segmented_nax", "steel_attention_nax", "quantized_nax", "fp_quantized_nax",
  ]

  init(context: DependencyVersionsContext, configuration: String) {
    self.context = context
    directory = context.proof.appendingPathComponent("shaders/" + configuration)
  }

  func add(_ source: URL, _ destination: URL, _ name: String) throws {
    Output.debug("versions.shader.verify source=\(source.path) destination=\(destination.path)")
    let sourceData = try Data(contentsOf: source)
    let destinationData = try Data(contentsOf: destination)
    try requireMaintenanceCondition(
      !sourceData.isEmpty && !destinationData.isEmpty, "Empty shader artifact")
    let digest = maintenanceSHA256(sourceData)
    try requireMaintenanceCondition(
      maintenanceSHA256(destinationData) == digest,
      "Staged shader differs from its source: \(destination.path)")
    try context.copy(destination, to: directory.appendingPathComponent(name))
    records.append(
      DependencyVersionsShaderRecord(
        source: source.path, destination: destination.path, sha256: digest))
  }
}

// MARK: - Built artifact verification

extension DependencyVersionsContext {
  func artifacts(configuration: String) throws {
    try requireMaintenanceCondition(
      ["Release", "Debug"].contains(configuration), "Select Release or Debug artifact proof")
    try verify()
    let archive = DependencyVersionsShaderArchive(context: self, configuration: configuration)
    if configuration == "Release" {
      try releaseArtifacts(archive)
    } else {
      try debugArtifacts(archive)
    }
    try writeJSON(
      archive.records,
      to: proof.appendingPathComponent(configuration.lowercased() + "-shaders.json"))
    Output.log("Verified and copied \(archive.records.count) source-built shader artifacts")
  }

  private func defaultShader(configuration: String) -> URL {
    root.appendingPathComponent(
      "Derived/Build/Products/" + configuration
        + "/mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib")
  }

  private func releaseArtifacts(_ archive: DependencyVersionsShaderArchive) throws {
    let products = root.appendingPathComponent("Products/Build/Release")
    let derived = defaultShader(configuration: "Release")
    try archive.add(
      derived,
      products.appendingPathComponent("mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib"),
      "lmd/bundle-default.metallib")
    try archive.add(
      derived, products.appendingPathComponent("default.metallib"), "lmd/adjacent-default.metallib")
    let child = try binaryDirectory(
      package: root.appendingPathComponent("SwiftLM"), configuration: "Release", native: false)
    try archive.add(
      child.appendingPathComponent("default.metallib"),
      products.appendingPathComponent("swiftlm/default.metallib"),
      "swiftlm/default.metallib")
    for name in archive.names {
      try archive.add(
        root.appendingPathComponent("Derived/nax/" + name + ".metallib"),
        products.appendingPathComponent("nax/" + name + ".metallib"),
        "lmd/nax/" + name + ".metallib")
      try archive.add(
        child.appendingPathComponent("nax/" + name + ".metallib"),
        products.appendingPathComponent("swiftlm/nax/" + name + ".metallib"),
        "swiftlm/nax/" + name + ".metallib")
    }
    try stateBinaries(products: products, child: child)
  }

  private func debugArtifacts(_ archive: DependencyVersionsShaderArchive) throws {
    let binary = try binaryDirectory(package: root, configuration: "Debug", native: true)
    let runner = binary.appendingPathComponent("lmdPackageTests.xctest/Contents/MacOS")
    try archive.add(
      defaultShader(configuration: "Debug"),
      runner.appendingPathComponent("mlx.metallib"),
      "tests/mlx.metallib")
    for name in archive.names {
      try archive.add(
        root.appendingPathComponent("Derived/nax/" + name + ".metallib"),
        runner.appendingPathComponent("nax/" + name + ".metallib"),
        "tests/nax/" + name + ".metallib")
    }
  }
  func stateBinaries(products: URL, child: URL) throws {
    Output.debug("versions.binary.verify products=\(products.path)")
    var state = try readState()
    let native = try binaryDirectory(package: root, configuration: "Release", native: true)
    let names = ["lmd", "lmd-serve", "lmd-model-host"]
    for name in names {
      try requireMaintenanceCondition(
        maintenanceSHA256(Data(contentsOf: products.appendingPathComponent(name)))
          == maintenanceSHA256(Data(contentsOf: native.appendingPathComponent(name))),
        "Staged root executable differs from its native Release build: \(name)")
    }
    var binaries: [String: String] = [:]
    for name in names + ["swiftlm/SwiftLM"] {
      binaries[name] = maintenanceSHA256(
        try Data(contentsOf: products.appendingPathComponent(name)))
    }
    try requireMaintenanceCondition(
      binaries["swiftlm/SwiftLM"]
        == maintenanceSHA256(Data(contentsOf: child.appendingPathComponent("SwiftLM"))),
      "Staged SwiftLM binary differs from its build")
    state.binaries = binaries
    try writeJSON(state, to: stateURL)
  }

  private func binaryDirectory(package: URL, configuration: String, native: Bool) throws -> URL {
    Output.debug(
      "versions.binary_directory.query package=\(package.path) configuration=\(configuration)")
    guard let executable = environment["SWIFT_MK_BIN"],
      FileManager.default.isExecutableFile(atPath: executable)
    else {
      throw MaintenanceError.failure("Set SWIFT_MK_BIN to the executable swift-mk toolchain")
    }
    let cacheArguments =
      native ? "--build-system native --jobs 4 -Xswiftc -explicit-module-build" : ""
    let output = try command(
      root,
      executable,
      [
        "toolchain", "swiftpm", "bin-path", "--package-path", package.path, "--configuration",
        configuration,
      ],
      overrides: [
        "SWIFT_MK_SWIFTPM_CACHE_ARGS": cacheArguments,
        "SWIFT_MK_SWIFTPM_COMPILE_CACHE_ENABLED": "NO",
      ])
    guard let path = output.split(whereSeparator: \.isNewline).last, path.hasPrefix("/") else {
      throw MaintenanceError.failure("swift-mk did not return an absolute SwiftPM binary directory")
    }
    return URL(fileURLWithPath: String(path))
  }

}
