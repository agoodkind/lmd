//
//  DevTool+Support.swift
//  lmd-dev
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-05-10.
//  Copyright © 2026, all rights reserved.
//

import Foundation
import SwiftMkCore

/// A `key=value` line splits into exactly this many parts.
private let keyValuePairComponentCount = 2
/// The shortest a `"x"` quoted value can be before the surrounding quotes strip.
private let quotedValueMinimumLength = 2

// MARK: - Environment

struct Environment {
  let values: [String: String]

  init() {
    values = ProcessInfo.processInfo.environment
  }

  func value(_ name: String, default defaultValue: String) -> String {
    values[name] ?? defaultValue
  }

  func required(_ name: String) throws -> String {
    guard let value = values[name], !value.isEmpty else {
      throw ToolError.failure("\(name) is not set")
    }
    return value
  }
}

// MARK: - Dictionary

extension Dictionary where Key == String, Value == String {
  func required(_ key: String) throws -> String {
    guard let value = self[key], !value.isEmpty else {
      throw ToolError.failure("\(key) not set")
    }
    return value
  }
}

// MARK: - Path resolution

extension DevTool {
  func buildDirectory(configuration: String) -> URL {
    productsDirectory().appendingPathComponent("Build").appendingPathComponent(configuration)
  }

  func derivedProductsDirectory(configuration: String) -> URL {
    repoRoot.appendingPathComponent("Derived/Build/Products").appendingPathComponent(configuration)
  }

  func releaseBuildDirectory() -> URL {
    if let override = environment.values["LMD_BUILD_DIR"], !override.isEmpty {
      return URL(fileURLWithPath: override, relativeTo: repoRoot).standardizedFileURL
    }
    if let binaryDirectory = environment.values["LMD_BINARY_DIR"], !binaryDirectory.isEmpty {
      return URL(fileURLWithPath: binaryDirectory, relativeTo: repoRoot).standardizedFileURL
    }
    return buildDirectory(configuration: "Release")
  }

  /// SwiftPM's product directory: `.build/<configuration>/` relative to the
  /// repo root. Configuration is the lower-cased SwiftPM form (`debug`,
  /// `release`).
  func swiftPackageBuildDirectory(configuration: String) -> URL {
    repoRoot
      .appendingPathComponent(".build")
      .appendingPathComponent(swiftPackageConfiguration(configuration))
  }

  /// Map an Xcode-style configuration name (`Release`, `Debug`) to the
  /// lower-cased form SwiftPM expects on `-c`.
  func swiftPackageConfiguration(_ configuration: String) -> String {
    configuration.lowercased()
  }

  func productsDirectory() -> URL {
    repoRoot.appendingPathComponent("Products")
  }

  func prefixDirectory() -> URL {
    URL(
      fileURLWithPath: environment.value(
        "PREFIX",
        default: "\(homeDirectory().path)/Library/Application Support/io.goodkind.lmd")
    )
    .standardizedFileURL
  }

  func homeDirectory() -> URL {
    URL(fileURLWithPath: NSHomeDirectory())
  }

  func agentPlistURL() -> URL {
    homeDirectory().appendingPathComponent("Library/LaunchAgents/io.goodkind.lmd.serve.plist")
  }

  func relativePath(_ url: URL) -> String {
    let root = repoRoot.path
    if url.path.hasPrefix(root) {
      return String(url.path.dropFirst(root.count + 1))
    }
    return url.path
  }
}

// MARK: - Process execution

extension DevTool {
  @discardableResult
  func runPassthrough(
    _ executable: String,
    _ arguments: [String],
    currentDirectory: URL? = nil,
    environment: [String: String]? = nil
  ) throws -> CommandResult {
    Output.debug("runPassthrough executable=\(executable)")
    return try run(
      executable,
      arguments,
      currentDirectory: currentDirectory,
      environment: environment,
      captureOutput: false
    )
  }

  func runCaptured(
    _ executable: String,
    _ arguments: [String],
    currentDirectory: URL? = nil,
    environment: [String: String]? = nil
  ) throws -> CommandResult {
    Output.debug("runCaptured executable=\(executable)")
    return try run(
      executable,
      arguments,
      currentDirectory: currentDirectory,
      environment: environment,
      captureOutput: true
    )
  }

  func run(
    _ executable: String,
    _ arguments: [String],
    currentDirectory: URL?,
    environment: [String: String]?,
    captureOutput: Bool
  ) throws -> CommandResult {
    Output.debug("run executable=\(executable)")
    let process = Process()
    if executable.hasPrefix("/") || executable.hasPrefix(".") {
      process.executableURL = URL(fileURLWithPath: executable)
      process.arguments = arguments
    } else {
      process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
      process.arguments = [executable] + arguments
    }
    process.currentDirectoryURL = currentDirectory ?? repoRoot
    process.environment = environment ?? ProcessInfo.processInfo.environment

    let pipe = Pipe()
    if captureOutput {
      process.standardOutput = pipe
      process.standardError = pipe
    }

    try process.run()
    process.waitUntilExit()

    var output = ""
    if captureOutput {
      let data = pipe.fileHandleForReading.readDataToEndOfFile()
      output = String(data: data, encoding: .utf8) ?? ""
    }

    if process.terminationStatus != 0 {
      if captureOutput, !output.isEmpty {
        try write(output)
      }
      throw ToolError.failure(
        "command failed (\(process.terminationStatus)): \(([executable] + arguments).joined(separator: " "))"
      )
    }

    return CommandResult(status: process.terminationStatus, output: output)
  }
}

// MARK: - File operations

extension DevTool {
  func decodeBase64Environment(_ name: String) throws -> Data {
    let value = try environment.required(name)
    guard let data = Data(base64Encoded: value) else {
      throw ToolError.failure("\(name) is not valid base64")
    }
    return data
  }

  func appendGitHubOutput(name: String, value: String) throws {
    guard let path = environment.values["GITHUB_OUTPUT"], !path.isEmpty else {
      return
    }
    try appendLine("\(name)=\(value)", to: URL(fileURLWithPath: path))
  }

  func appendLine(_ line: String, to url: URL) throws {
    Output.debug("appendLine path=\(url.path)")
    let data = Data((line + "\n").utf8)
    if fileManager.fileExists(atPath: url.path) {
      let handle = try FileHandle(forWritingTo: url)
      defer {
        do {
          try handle.close()
        } catch {
          Output.warning("appendLine close failed path=\(url.path) error=\(error)")
        }
      }
      try handle.seekToEnd()
      try handle.write(contentsOf: data)
    } else {
      try data.write(to: url, options: .atomic)
    }
  }

  func removeIfExists(_ url: URL) throws {
    Output.debug("removeIfExists path=\(url.path)")
    if fileManager.fileExists(atPath: url.path) {
      try fileManager.removeItem(at: url)
    }
  }

  func copyReplacingItem(at source: URL, to destination: URL) throws {
    Output.debug("copyReplacingItem source=\(source.lastPathComponent)")
    try removeIfExists(destination)
    try fileManager.copyItem(at: source, to: destination)
  }

  func stageCompatibilityLinks(in directory: URL) throws {
    Output.debug("stageCompatibilityLinks directory=\(directory.path)")
    for (linkName, destinationName) in compatibilityCommandLinks {
      let linkPath = directory.appendingPathComponent(linkName)
      try removeIfExists(linkPath)
      try fileManager.createSymbolicLink(
        atPath: linkPath.path, withDestinationPath: destinationName)
      try writeLine("  linked \(linkName) -> \(destinationName)")
    }
  }

  func temporaryDirectory(prefix: String) throws -> URL {
    Output.debug("temporaryDirectory prefix=\(prefix)")
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("\(prefix).\(UUID().uuidString)")
    try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  func temporaryFileURL(prefix: String, suffix: String) -> URL {
    URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("\(prefix).\(UUID().uuidString)\(suffix)")
  }

  func parseKeyValueFile(_ url: URL) throws -> [String: String] {
    Output.debug("parseKeyValueFile path=\(url.path)")
    let content = try String(contentsOf: url, encoding: .utf8)
    var values: [String: String] = [:]
    for rawLine in content.components(separatedBy: .newlines) {
      let line = rawLine.trimmingCharacters(in: .whitespaces)
      if line.isEmpty || line.hasPrefix("#") {
        continue
      }
      let parts = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
      if parts.count != keyValuePairComponentCount {
        continue
      }
      let key = String(parts[0]).trimmingCharacters(in: .whitespaces)
      var value = String(parts[1]).trimmingCharacters(in: .whitespaces)
      if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= quotedValueMinimumLength {
        value.removeFirst()
        value.removeLast()
      }
      values[key] = value
    }
    return values
  }

  func sourceSwiftFiles(excludingPathComponent excluded: String) -> [URL] {
    let sources = repoRoot.appendingPathComponent("Sources")
    guard let enumerator = fileManager.enumerator(at: sources, includingPropertiesForKeys: nil)
    else {
      return []
    }
    var files: [URL] = []
    for case let file as URL in enumerator {
      if file.pathComponents.contains(excluded) {
        enumerator.skipDescendants()
        continue
      }
      if file.pathExtension == "swift" {
        files.append(file)
      }
    }
    return files
  }
}

// MARK: - Formatting and prompts

extension DevTool {
  func artifactStamp() -> String {
    artifactDateFormatter().string(from: Date())
  }

  func artifactDateFormatter() -> DateFormatter {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyyMMdd-HHmmss"
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    return formatter
  }

  func logDateFormatter() -> DateFormatter {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd HH:mm:ssZ"
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    return formatter
  }

  func prompt(_ message: String) -> String {
    do {
      try write(message)
    } catch {
      Output.warning("prompt write failed error=\(error)")
    }
    return readLine() ?? ""
  }

  func writeLine(_ message: String) throws {
    try write(message + "\n")
  }

  func write(_ message: String) throws {
    try FileHandle.standardOutput.write(contentsOf: Data(message.utf8))
  }
}
