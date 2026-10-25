//
//  CoreToolVerification.swift
//  lmd-maintenance
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-10-25.
//  Copyright © 2026, all rights reserved.
//

import Foundation
import SwiftMkCore

enum CoreToolVerification {
  private static let commandTimeoutSeconds: Double = 30
  private static let inconclusiveStatus: Int32 = 2
  private static let completedStressRounds = 20

  static func verifyCompileLockRepro(_ arguments: [String]) throws {
    Output.debug("maintenance.compile_lock argument_count=\(arguments.count)")
    try requireMaintenanceCondition(
      arguments.count == 1, "Usage: verify-compile-lock-repro EXECUTABLE")
    let executable = URL(fileURLWithPath: arguments[0]).standardizedFileURL
    try requireMaintenanceCondition(
      FileManager.default.isExecutableFile(atPath: executable.path),
      "Build CompileLockRepro and specify its executable path: \(executable.path)")
    try withTemporaryDirectory(prefix: "compile-lock-verification-") { directory in
      let environment = [
        "LLVM_PROFILE_FILE": directory.appendingPathComponent("profile-%p.profraw").path
      ]
      for disabled in [false, true] {
        var child = ["-u", "MLX_DISABLE_COMPILE"]
        if disabled {
          child.append("MLX_DISABLE_COMPILE=1")
        }
        child += [executable.path, "--device", "cpu"]
        let result = try run(child, environment: environment)
        try verifyInconclusive(result)
      }
      let missingValue = try run(
        ["-u", "MLX_DISABLE_COMPILE", executable.path, "--device"], environment: environment)
      try requireMaintenanceCondition(
        missingValue.status == inconclusiveStatus
          && missingValue.stdout.contains("--device requires cpu or gpu"),
        "CompileLockRepro did not reject a missing device value with status 2.")
    }
    Output.log("CompileLockRepro: 3 real process cases passed.")
  }

  static func verifyManifestFixtures(_ arguments: [String]) throws {
    Output.debug("maintenance.manifest_fixtures argument_count=\(arguments.count)")
    try requireMaintenanceCondition(
      arguments.count == 1, "Usage: verify-manifest-fixtures CORE_REPOSITORY")
    let repository = URL(fileURLWithPath: arguments[0]).standardizedFileURL
    let verifier = repository.appendingPathComponent("scripts/verify-spm-manifest.py")
    let fixture = repository.appendingPathComponent("Tests/ManifestValidationTests/Package.swift")
    for path in [verifier, fixture] {
      try requireMaintenanceCondition(
        FileManager.default.isReadableFile(atPath: path.path),
        "Use a core checkout containing \(path.path).")
    }
    let template = try String(contentsOf: fixture, encoding: .utf8)
    #if os(Linux)
      let acceptedPlugin = "CudaBuild"
      let rejectedPlugin = "OtherBuild"
    #else
      let acceptedPlugin = "OtherBuild"
      let rejectedPlugin = "CudaBuild"
    #endif
    let accepted = try verifyManifest(
      template: template, plugin: acceptedPlugin, verifier: verifier)
    try requireMaintenanceCondition(
      accepted.status == 0
        && accepted.stdout.contains("SwiftPM manifest CUDA containment passed"),
      "The manifest validator rejected the required platform plugin identity.")
    let rejected = try verifyManifest(
      template: template, plugin: rejectedPlugin, verifier: verifier)
    try requireMaintenanceCondition(
      rejected.status != 0
        && (rejected.stderr.contains("CUDA build plugin")
          || rejected.stderr.contains("CUDA build targets")),
      "The manifest validator did not reject the incorrect CUDA plugin identity.")
    Output.log("Manifest validation: 2 real SwiftPM fixture cases passed.")
  }

  private static func verifyInconclusive(_ result: Shell.ForwardingStreamingResult) throws {
    try requireMaintenanceCondition(
      result.status == inconclusiveStatus,
      "CompileLockRepro must report an inconclusive run with status 2; received \(result.status).")
    try requireMaintenanceCondition(
      result.stdout.contains("INCONCLUSIVE:")
        && result.stdout.contains("\(completedStressRounds) stress rounds completed"),
      "CompileLockRepro did not report \(completedStressRounds) completed inconclusive stress rounds."
    )
    try requireMaintenanceCondition(
      !result.stdout.components(separatedBy: .newlines).contains { $0.hasPrefix("PASS:") }
        && !result.stdout.contains("enteredTrace"),
      "CompileLockRepro reported unsupported trace or success evidence.")
  }

  private static func verifyManifest(
    template: String, plugin: String, verifier: URL
  ) throws -> Shell.ForwardingStreamingResult {
    try withTemporaryDirectory(prefix: "manifest-verification-") { directory in
      let manifest = template.replacingOccurrences(of: "__PLUGIN_NAME__", with: plugin)
      try manifest.write(
        to: directory.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
      return try run(["-C", directory.path, "python3", verifier.path])
    }
  }

  private static func run(
    _ arguments: [String], environment: [String: String] = [:]
  ) throws -> Shell.ForwardingStreamingResult {
    let result = Shell.runForwardingAndCapturingStreaming(
      "/usr/bin/env",
      arguments,
      environment: environment,
      timeoutSeconds: commandTimeoutSeconds)
    try requireMaintenanceCondition(
      !result.timedOut,
      "Core tool verification exceeded its \(Int(commandTimeoutSeconds))-second deadline.")
    return result
  }

  private static func withTemporaryDirectory<Value>(
    prefix: String, _ body: (URL) throws -> Value
  ) throws -> Value {
    Output.debug("maintenance.core_tool_temporary_directory prefix=\(prefix)")
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(prefix + UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let result: Result<Value, any Error>
    do {
      result = .success(try body(directory))
    } catch {
      result = .failure(error)
    }
    do {
      try FileManager.default.removeItem(at: directory)
    } catch {
      if case .failure(let operationError) = result {
        throw MaintenanceError.failure(
          "Core tool verification failed: \(operationError). "
            + "Remove temporary directory \(directory.path): \(error)")
      }
      throw MaintenanceError.failure("Remove temporary directory \(directory.path): \(error)")
    }
    return try result.get()
  }
}
