//
//  DependencyVersionsCommand.swift
//  lmd-maintenance
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-10-25.
//  Copyright © 2026, all rights reserved.
//

import Foundation
import SwiftMkCore

// MARK: - Arguments

private enum DependencyVersionsArguments {
  static let normalCount = 5
  static let artifactCount = 6
  static let root = 1
  static let core = 2
  static let library = 3
  static let proof = 4
  static let configuration = 5
}

// MARK: - Version commands

enum DependencyVersionsCommand {
  static func run(_ arguments: [String]) throws {
    try requireMaintenanceCondition(
      arguments.count == DependencyVersionsArguments.normalCount
        || arguments.count == DependencyVersionsArguments.artifactCount,
      "Usage: prepare-versions|verify-versions <lmd> <core> <library> <proof>; "
        + "verify-artifacts <lmd> <core> <library> <proof> Release|Debug"
    )
    let context = try DependencyVersionsContext(arguments: arguments)
    switch arguments[0] {
    case "prepare": try context.prepare()
    case "verify": try context.verify()
    case "artifacts":
      try requireMaintenanceCondition(
        arguments.count == DependencyVersionsArguments.artifactCount,
        "Select Release or Debug artifact proof")
      try context.artifacts(configuration: arguments[DependencyVersionsArguments.configuration])
    default: throw MaintenanceError.failure("Select prepare, verify, or artifacts")
    }
  }
}

// MARK: - Proof models

struct DependencyVersionsState: Codable {
  var libraryCommitSha256: String
  var requested: [String: String]
  var effectiveLibrary: String
  var libraryBase: String
  var oldCoreRequirement: String
  var newCoreRequirement: String
  var libraryOverlaySha256: String
  var libraryOverlayTree: String
  var libraryOverlayRef: String?
  var runtimeSourceComparison: String
  var mirrors: [String: String]
  var resolved: [DependencyVersionsResolvedPackage]?
  var swiftlmLockSha256: String?
  var binaries: [String: String]?
}

// MARK: - DependencyVersionsResolvedPackage

struct DependencyVersionsResolvedPackage: Codable {
  let package: String
  let sha256: String
  let revisions: [String: String]
}

// MARK: - Selected source inputs

final class DependencyVersionsContext {
  let root: URL
  let core: URL
  let library: URL
  let proof: URL
  let refs: [String: String]
  var environment: [String: String]
  let packagePaths = ["", "Tools", "Tuist"]
  let identities = ["mlx-swift", "mlx-swift-lm"]

  init(arguments: [String], environment: [String: String] = ProcessInfo.processInfo.environment)
    throws
  {
    root = URL(fileURLWithPath: arguments[DependencyVersionsArguments.root]).standardizedFileURL
    core = URL(fileURLWithPath: arguments[DependencyVersionsArguments.core]).standardizedFileURL
    library =
      URL(fileURLWithPath: arguments[DependencyVersionsArguments.library]).standardizedFileURL
    proof = URL(fileURLWithPath: arguments[DependencyVersionsArguments.proof]).standardizedFileURL
    self.environment = environment
    var selected: [String: String] = [:]
    for key in ["LMD_REF", "CORE_REF", "LIBRARY_REF", "SWIFTLM_REF"] {
      guard let value = environment[key],
        value.range(of: "^[0-9a-f]{40}$", options: .regularExpression) != nil
      else {
        throw MaintenanceError.failure("Set \(key) to a full immutable commit SHA")
      }
      selected[key] = value
    }
    refs = selected
    try requireMaintenanceCondition(
      !identities.contains(root.lastPathComponent.lowercased()),
      "Use an LMD checkout directory that does not match an MLX dependency identity, such as lmd")
  }

  var stateURL: URL { proof.appendingPathComponent("versions.json") }

  func ref(_ key: String) throws -> String {
    guard let value = refs[key] else { throw MaintenanceError.failure("Set \(key)") }
    return value
  }

  // MARK: - Subprocesses

  @discardableResult
  func command(
    _ directory: URL,
    _ executable: String,
    _ arguments: [String],
    streaming: Bool = false,
    overrides: [String: String] = [:]
  ) throws -> String {
    Output.debug("versions.command executable=\(executable) directory=\(directory.path)")
    let childEnvironment = environment.merging(overrides) { _, replacement in replacement }
    let commandArguments = ["-C", directory.path, executable] + arguments
    if streaming {
      let status = Shell.runForwardingOutput(
        "/usr/bin/env", commandArguments, environment: childEnvironment)
      try requireMaintenanceCondition(
        status == 0, "\(executable) failed with exit status \(status)")
      return ""
    }
    let result = Shell.run("/usr/bin/env", commandArguments, environment: childEnvironment)
    try requireMaintenanceCondition(
      result.status == 0, "\(executable) failed with exit status \(result.status): \(result.stderr)"
    )
    return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  @discardableResult
  func git(_ directory: URL, _ arguments: [String]) throws -> String {
    try command(directory, "git", arguments)
  }

  func gitArchive(_ directory: URL, _ arguments: [String], destination: URL) throws {
    Output.debug("versions.archive.write path=\(destination.path)")
    try Data().write(to: destination)
    try withWritableFile(destination) { handle in
      let process = Process()
      process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
      process.arguments = ["git"] + arguments
      process.currentDirectoryURL = directory
      process.environment = environment
      process.standardOutput = handle
      try process.run()
      process.waitUntilExit()
      try requireMaintenanceCondition(
        process.terminationStatus == 0,
        "git archive command failed with exit status \(process.terminationStatus)")
    }
  }

  // MARK: - Proof files

  func withWritableFile(_ url: URL, operation: (FileHandle) throws -> Void) throws {
    Output.debug("versions.file.open path=\(url.path)")
    let handle = try FileHandle(forWritingTo: url)
    do {
      try operation(handle)
      try handle.close()
    } catch {
      let operationFailure = error
      do { try handle.close() } catch {
        Output.error("versions.file.close_failed path=\(url.path) error=\(error)")
      }
      throw operationFailure
    }
  }

  func writeJSON<T: Encodable>(_ value: T, to url: URL) throws {
    Output.debug("versions.proof.write path=\(url.path)")
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    encoder.keyEncodingStrategy = .convertToSnakeCase
    var data = try encoder.encode(value)
    data.append(contentsOf: "\n".utf8)
    try data.write(to: url)
  }

  func readState() throws -> DependencyVersionsState {
    Output.debug("versions.proof.read path=\(stateURL.path)")
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    return try decoder.decode(DependencyVersionsState.self, from: Data(contentsOf: stateURL))
  }

  func copy(_ source: URL, to destination: URL) throws {
    Output.debug("versions.file.copy source=\(source.path) destination=\(destination.path)")
    try FileManager.default.createDirectory(
      at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(contentsOf: source).write(to: destination)
  }

  func lockName(_ packagePath: String) -> String {
    packagePath.isEmpty ? "Package.resolved" : packagePath.lowercased() + "-Package.resolved"
  }

  func snapshotLocks() throws {
    for packagePath in packagePaths {
      try copy(
        root.appendingPathComponent(packagePath).appendingPathComponent("Package.resolved"),
        to: proof.appendingPathComponent(lockName(packagePath)))
    }
    try copy(
      root.appendingPathComponent("SwiftLM/Package.resolved"),
      to: proof.appendingPathComponent("swiftlm-Package.resolved"))
  }
}
