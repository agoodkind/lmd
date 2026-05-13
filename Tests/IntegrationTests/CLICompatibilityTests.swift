//
//  CLICompatibilityTests.swift
//  IntegrationTests
//
//  Verifies the single foreground CLI and the compatibility symlinks both
//  resolve to the expected help surfaces from staged release artifacts.
//

import Foundation
import XCTest

final class CLICompatibilityTests: XCTestCase {
  func testRootHelpFromLmdBinary() throws {
    let binary = try resolveBinary("lmd")
    let result = try run(binary: binary, arguments: ["--help"])
    XCTAssertEqual(result.status, 0)
    XCTAssertTrue(result.output.contains("SUBCOMMANDS:") || result.output.contains("OVERVIEW:"))
  }

  func testTUICompatibilityLinkShowsTUIHelp() throws {
    let binary = try resolveBinary("lmd-tui")
    let result = try run(binary: binary, arguments: ["--help"])
    XCTAssertEqual(result.status, 0)
    XCTAssertTrue(result.output.contains("Launch the multi-tab TUI."))
  }

  func testBenchCompatibilityLinkShowsBenchHelp() throws {
    let binary = try resolveBinary("lmd-bench")
    let result = try run(binary: binary, arguments: ["--help"])
    XCTAssertEqual(result.status, 0)
    XCTAssertTrue(result.output.contains("Run the benchmark orchestrator."))
  }

  func testQACompatibilityLinkShowsQAHelp() throws {
    let binary = try resolveBinary("lmd-qa")
    let result = try run(binary: binary, arguments: ["--help"])
    XCTAssertEqual(result.status, 0)
    XCTAssertTrue(result.output.contains("Run the TUI QA harness."))
  }

  private func run(binary: URL, arguments: [String]) throws -> (status: Int32, output: String) {
    let process = Process()
    process.executableURL = binary
    process.arguments = arguments
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    try process.run()
    process.waitUntilExit()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    let output = String(data: data, encoding: .utf8) ?? ""
    return (process.terminationStatus, output)
  }

  private func resolveBinary(_ name: String) throws -> URL {
    let env = ProcessInfo.processInfo.environment
    if let override = env["LMD_BINARY_DIR"], !override.isEmpty {
      let candidate = URL(fileURLWithPath: override).appendingPathComponent(name)
      if FileManager.default.isExecutableFile(atPath: candidate.path) {
        return candidate
      }
    }

    let root = try repoRoot()
    let candidates = [
      root
        .appendingPathComponent("Products", isDirectory: true)
        .appendingPathComponent("Build", isDirectory: true)
        .appendingPathComponent("Release", isDirectory: true)
        .appendingPathComponent(name),
      root
        .appendingPathComponent(".build", isDirectory: true)
        .appendingPathComponent("release", isDirectory: true)
        .appendingPathComponent(name),
    ]
    for candidate in candidates where FileManager.default.isExecutableFile(atPath: candidate.path) {
      return candidate
    }
    throw XCTSkip("release binary not found for \(name). Run `make build` first.")
  }

  private func repoRoot() throws -> URL {
    var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    while dir.path != "/" {
      if FileManager.default.fileExists(
        atPath: dir.appendingPathComponent("Package.swift").path
      ) {
        return dir
      }
      dir = dir.deletingLastPathComponent()
    }
    throw XCTSkip("could not locate Package.swift above \(#filePath)")
  }
}
