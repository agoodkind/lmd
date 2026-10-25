//
//  TestResultVerificationTests.swift
//  LMDMaintenanceTests
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-10-25.
//  Copyright © 2026, all rights reserved.
//

import Foundation
import Nimble
import SwiftMkCore
import Synchronization
import XCTest

#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#endif

final class TestResultVerificationTests: XCTestCase {
  private static let processTimeoutSeconds: Double = 60
  private static let releaseTimeoutSeconds: Double = 20
  private static let expectedTestCount = 2
  private static let outcomeEnvironmentKey = "LMD_VERIFIER_OUTCOME"
  private static let releaseEnvironmentKey = "LMD_VERIFIER_RELEASE_FILE"
  private static let readinessMessage = "The real XCTest fixture is waiting for release."

  func testRealXCTestPassFailureSkipAndEarlyExit() throws {
    let fixture = try makePackage()
    defer {
      expect { try self.removePackage(fixture) }.toNot(throwError())
    }
    let binary = try maintenanceBinary()
    let passing = try runTests(in: fixture, outcome: "pass", skipBuild: false)
    try requireSuccess(passing.execution, operation: "The real passing XCTest run")
    let discovery = try discover(in: fixture)
    guard discovery.output.contains("ProbeTests.ProbeTests/testFirst"),
      discovery.output.contains("ProbeTests.ProbeTests/testOutcome")
    else {
      throw TestFixtureError(description: "Discovery did not list both real XCTest methods.")
    }
    let passed = verify(passing, discovery: discovery.report, binary: binary)
    try requireSuccess(passed, operation: "Verification of the real passing XCTest run")
    expect(passed.combined).to(contain("\(Self.expectedTestCount) discovered cases completed"))

    for outcome in ["fail", "skip", "abort"] {
      let actual = try runTests(in: fixture, outcome: outcome, skipBuild: true)
      guard actual.output.contains(Self.outcomeCasePrefix + " started")
      else {
        throw TestFixtureError(
          description: "The real \(outcome) XCTest case did not start: \(actual.output)")
      }
      if outcome == "fail" {
        expect(actual.execution.status) != 0
        expect(actual.output).to(contain(Self.outcomeCasePrefix + " failed"))
      } else {
        try requireSuccess(actual.execution, operation: "The real \(outcome) XCTest run")
      }
      if outcome == "skip" {
        expect(actual.output).to(
          contain(Self.outcomeCasePrefix + " skipped"))
      }
      let rejected = verify(actual, discovery: discovery.report, binary: binary)
      expect(rejected.status) != 0
      expect(rejected.timedOut) == false
      expect(rejected.combined).to(contain("XCTest"))
    }

    try verifyProgressBeforeRelease(in: fixture, binary: binary)
  }

  func testDuplicateClassNamesRetainModuleIdentity() throws {
    let fixture = try makePackage(duplicateClassNames: true)
    defer {
      expect { try self.removePackage(fixture) }.toNot(throwError())
    }
    let actual = try runTests(in: fixture, outcome: "pass", skipBuild: false)
    try requireSuccess(actual.execution, operation: "The real two-module XCTest run")
    let discovery = try discover(in: fixture)
    guard discovery.output.contains("ProbeTests.ProbeTests/testOutcome"),
      discovery.output.contains("OtherProbeTests.ProbeTests/testOutcome")
    else {
      throw TestFixtureError(description: "Discovery did not list both real modules.")
    }
    let checked = verify(
      actual,
      discovery: discovery.report,
      binary: try maintenanceBinary(),
      selector: "ProbeTests.ProbeTests")
    #if os(Linux)
      expect(checked.status) != 0
      expect(checked.combined).to(contain("Ambiguous unqualified XCTest class"))
    #else
      try requireSuccess(checked, operation: "Verification of the qualified Apple XCTest class")
    #endif
  }

}

// MARK: - Fixture Commands

extension TestResultVerificationTests {
  private func discover(in fixture: URL) throws -> TestFixtureRun {
    let discovered = try runSwift(
      [
        "test", "--package-path", fixture.path, "list", "--skip-build",
        "--disable-swift-testing",
      ], in: fixture)
    try requireSuccess(discovered.execution, operation: "Real XCTest discovery")
    return discovered
  }

  private func runTests(
    in fixture: URL, outcome: String, skipBuild: Bool
  ) throws -> TestFixtureRun {
    var arguments = [
      "test", "--package-path", fixture.path,
    ]
    if skipBuild {
      arguments.append("--skip-build")
    }
    arguments.append("--disable-swift-testing")
    return try runSwift(
      arguments,
      in: fixture,
      environment: [Self.outcomeEnvironmentKey: outcome])
  }

  private func runSwift(
    _ arguments: [String], in fixture: URL, environment: [String: String] = [:]
  ) throws -> TestFixtureRun {
    let executable = try swiftMakefileBinary()
    let report = fixture.appendingPathComponent("swiftpm-\(UUID().uuidString).txt")
    let binary = try maintenanceBinary()
    var configuredEnvironment = environment
    configuredEnvironment["SWIFT_TEST_CMD"] = try swiftTestCommand(arguments)
    configuredEnvironment["SWIFT_MK_SWIFTPM_COMPILE_CACHE_ENABLED"] = "NO"
    let execution = Shell.runForwardingAndCapturingStreaming(
      binary.path,
      [
        "record", "--quiet", "--log", report.path,
        URL(fileURLWithPath: executable).standardizedFileURL.path, "test",
      ],
      environment: configuredEnvironment,
      timeoutSeconds: Self.processTimeoutSeconds)
    let output = try String(contentsOf: report, encoding: .utf8)
    guard !execution.timedOut else {
      throw TestFixtureError(
        description:
          "The real SwiftPM command returned unexpected timeout status \(execution.timedOut). "
          + "Report: \(report.path)\n\(output)\n\(execution.combined)")
    }
    return TestFixtureRun(
      execution: execution,
      report: report,
      output: output)
  }

  private func swiftMakefileBinary() throws -> String {
    guard let executable = ProcessInfo.processInfo.environment["SWIFT_MK_BIN"],
      !executable.isEmpty, FileManager.default.isExecutableFile(atPath: executable)
    else {
      throw CocoaError(
        .fileNoSuchFile,
        userInfo: [
          NSLocalizedDescriptionKey:
            "Run make test-tools with SWIFT_MK_BIN set to the canonical toolchain executable."
        ])
    }
    return URL(fileURLWithPath: executable).standardizedFileURL.path
  }

  private func verifyProgressBeforeRelease(in fixture: URL, binary: URL) throws {
    let report = fixture.appendingPathComponent("progress-\(UUID().uuidString).txt")
    let release = fixture.appendingPathComponent("release-\(UUID().uuidString).txt")
    let bundle = fixture.appendingPathComponent(".build/debug/ProbePackageTests.xctest")
    #if os(macOS)
      let childArguments = ["/usr/bin/xcrun", "xctest", bundle.path]
    #else
      let childArguments = [bundle.path]
    #endif
    let environment = [
      Self.outcomeEnvironmentKey: "progress",
      Self.releaseEnvironmentKey: release.path,
    ]
    let result = Mutex<Shell.ForwardingStreamingResult?>(nil)
    let finished = DispatchGroup()
    finished.enter()
    DispatchQueue.global().async {
      let execution = Shell.runForwardingAndCapturingStreaming(
        binary.path,
        ["record", "--quiet", "--log", report.path] + childArguments,
        environment: environment,
        timeoutSeconds: Self.processTimeoutSeconds)
      result.withLock { $0 = execution }
      finished.leave()
    }
    expect {
      guard FileManager.default.fileExists(atPath: report.path) else { return false }
      let output = try String(contentsOf: report, encoding: .utf8)
      return output.contains(Self.outcomeCasePrefix + " started")
        && output.contains(Self.readinessMessage)
    }.toEventually(beTrue(), timeout: .seconds(Int(Self.processTimeoutSeconds)))
    try Data().write(to: release)
    guard finished.wait(timeout: .now() + Self.processTimeoutSeconds) == .success,
      let execution = result.withLock({ $0 })
    else {
      throw TestFixtureError(description: "The released real XCTest fixture did not finish.")
    }
    try requireSuccess(execution, operation: "The real XCTest progress run")
    expect(execution.combined).toNot(contain(Self.readinessMessage))
    let output = try String(contentsOf: report, encoding: .utf8)
    let prefix = Self.readinessMessage + " "
    guard
      let line = output.components(separatedBy: .newlines).first(where: { $0.hasPrefix(prefix) }),
      let processID = Int32(line.dropFirst(prefix.count)), processID > 0
    else {
      throw TestFixtureError(
        description: "The real XCTest progress report did not include its PID.")
    }
    let processStatus = kill(processID, 0)
    let processError = errno
    expect(processStatus) == -1
    expect(processError) == ESRCH
  }

}

// MARK: - Fixture Files

extension TestResultVerificationTests {
  private func removePackage(_ fixture: URL) throws {
    do {
      try FileManager.default.removeItem(at: fixture)
    } catch {
      Output.logError("Fixture cleanup failed at \(fixture.path): \(error)")
      throw error
    }
  }

  private func swiftTestCommand(_ arguments: [String]) throws -> String {
    guard arguments.first == "test" else {
      throw TestFixtureError(description: "The fixture requires one swift test command.")
    }
    let options = ["--build-system", "native", "--jobs", "4", "-Xswiftc", "-explicit-module-build"]
    let quoted = (options + Array(arguments.dropFirst())).map { argument in
      "'" + argument.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
    return "swift test " + quoted.joined(separator: " ")
  }

  private static var outcomeCasePrefix: String {
    #if os(Linux)
      "Test Case 'ProbeTests.testOutcome'"
    #else
      "Test Case '-[ProbeTests.ProbeTests testOutcome]'"
    #endif
  }

  private func verify(
    _ actual: TestFixtureRun, discovery: URL, binary: URL, selector: String = "ProbeTests"
  ) -> Shell.ForwardingStreamingResult {
    Shell.runForwardingAndCapturingStreaming(
      binary.path,
      ["verify-test-results", "swiftpm", actual.report.path, discovery.path, selector],
      timeoutSeconds: Self.processTimeoutSeconds)
  }

  private func requireSuccess(
    _ result: Shell.ForwardingStreamingResult, operation: String
  ) throws {
    guard result.status == 0, !result.timedOut else {
      throw TestFixtureError(
        description:
          "\(operation) failed (status \(result.status), timeout \(result.timedOut)): \(result.combined)"
      )
    }
  }

  private func maintenanceBinary() throws -> URL {
    try MaintenanceTestExecutable.locate(for: Self.self)
  }

  private func makePackage(duplicateClassNames: Bool = false) throws -> URL {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("lmd-result-verifier 'quoted path'-\(UUID().uuidString)")
    let targetNames: [String]
    if duplicateClassNames {
      targetNames = ["ProbeTests", "OtherProbeTests"]
    } else {
      targetNames = ["ProbeTests"]
    }
    let declarations = targetNames.map { name in ".testTarget(name: \"\(name)\")" }
    let manifest = """
      // swift-tools-version: 6.0
      import PackageDescription
      let package = Package(
        name: "Probe",
        targets: [\(declarations.joined(separator: ", "))]
      )
      """
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try manifest.write(
      to: root.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
    for name in targetNames {
      let tests = root.appendingPathComponent("Tests/" + name)
      try FileManager.default.createDirectory(at: tests, withIntermediateDirectories: true)
      try Self.fixtureSource.write(
        to: tests.appendingPathComponent("ProbeTests.swift"), atomically: true, encoding: .utf8)
    }
    return root
  }

  private static var fixtureSource: String {
    """
    #if canImport(Darwin)
      import Darwin
    #elseif canImport(Glibc)
      import Glibc
    #endif
    import Foundation
    import XCTest

    final class ProbeTests: XCTestCase {
      private static let waitingIntervalSeconds: Double = 0.01
      private static let releaseTimeoutSeconds: Double = \(Self.releaseTimeoutSeconds)

      func testFirst() {
        XCTAssertNotNil(ProcessInfo.processInfo.environment["LMD_VERIFIER_OUTCOME"])
      }

      func testOutcome() throws {
        switch ProcessInfo.processInfo.environment["LMD_VERIFIER_OUTCOME"] {
        case "pass":
          return
        case "fail":
          XCTFail("The controlled XCTest run failed.")
        case "skip":
          throw XCTSkip("The controlled XCTest run skipped this case.")
        case "abort":
          fflush(nil)
          exit(0)
        case "progress":
          guard let release = ProcessInfo.processInfo.environment["LMD_VERIFIER_RELEASE_FILE"] else {
            XCTFail("Set LMD_VERIFIER_RELEASE_FILE for the progress case.")
            return
          }
          print("\(Self.readinessMessage) \\(getpid())")
          fflush(nil)
          let deadline = Date().addingTimeInterval(Self.releaseTimeoutSeconds)
          while !FileManager.default.fileExists(atPath: release), Date() < deadline {
            Thread.sleep(forTimeInterval: Self.waitingIntervalSeconds)
          }
          XCTAssertTrue(
            FileManager.default.fileExists(atPath: release), "The progress case did not receive release.")
        default:
          XCTFail("Set LMD_VERIFIER_OUTCOME before running this package.")
        }
      }
    }
    """
  }
}

// MARK: - TestFixtureRun

private struct TestFixtureRun {
  let execution: Shell.ForwardingStreamingResult
  let report: URL
  let output: String
}

// MARK: - TestFixtureError

private struct TestFixtureError: Error, CustomStringConvertible {
  let description: String
}
