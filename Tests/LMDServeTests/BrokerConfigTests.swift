//
//  BrokerConfigTests.swift
//  LMDServeTests
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-06-05.
//  Copyright © 2026, all rights reserved.
//

import Foundation
import XCTest

@testable import LMDServeSupport

final class BrokerConfigTests: XCTestCase {
  /// A complete, valid environment for every key. Tests mutate a copy to
  /// exercise individual failures.
  private func completeEnvironment() -> [String: String] {
    var env: [String: String] = [:]
    env[BrokerConfigKey.host.rawValue] = "localhost"
    env[BrokerConfigKey.port.rawValue] = "5400"
    env[BrokerConfigKey.reserveGB.rawValue] = "20"
    env[BrokerConfigKey.swiftlmBinary.rawValue] = "/usr/bin/true"
    env[BrokerConfigKey.chatMaxConcurrency.rawValue] = "4"
    env[BrokerConfigKey.embeddingMaxConcurrency.rawValue] = "4"
    env[BrokerConfigKey.batteryThrottlePct.rawValue] = "20"
    env[BrokerConfigKey.batteryResumePct.rawValue] = "80"
    env[BrokerConfigKey.disableXPC.rawValue] = "0"
    env[BrokerConfigKey.idleMinutes.rawValue] = "15"
    env[BrokerConfigKey.embeddingIdleMinutes.rawValue] = "60"
    env[BrokerConfigKey.dataDir.rawValue] = "/tmp"
    env[BrokerConfigKey.sampleInterval.rawValue] = "15"
    env[BrokerConfigKey.promptCacheMaxTokens.rawValue] = ""
    env[BrokerConfigKey.promptCacheEnabled.rawValue] = "true"
    env[BrokerConfigKey.mlxCacheLimitGB.rawValue] = "2"
    return env
  }

  private func config(_ env: [String: String]) throws -> BrokerConfig {
    try BrokerConfig(source: EnvironmentConfigSource(environment: env))
  }

  func testCompleteConfigParses() throws {
    let config = try config(completeEnvironment())
    XCTAssertEqual(config.host, "localhost")
    XCTAssertEqual(config.bindHost, "::1")
    XCTAssertEqual(config.port, 5400)
    XCTAssertEqual(config.reserveBytes, 20 * 1_073_741_824)
    XCTAssertEqual(config.swiftlmBinary, "/usr/bin/true")
    XCTAssertEqual(config.chatMaxConcurrency, 4)
    XCTAssertEqual(config.embeddingMaxConcurrency, 4)
    XCTAssertEqual(config.batteryThrottlePct, 20)
    XCTAssertEqual(config.batteryResumePct, 80)
    XCTAssertFalse(config.disableXPC)
    XCTAssertEqual(config.idleMinutes, 15)
    XCTAssertEqual(config.embeddingIdleMinutes, 60)
    XCTAssertEqual(config.dataDir, "/tmp")
    XCTAssertEqual(config.sampleInterval, 15, accuracy: 0.0001)
    XCTAssertTrue(config.promptCacheEnabled)
    XCTAssertNil(config.promptCacheMaxTokens)
    XCTAssertEqual(config.mlxCacheLimitBytes, 2 * 1_073_741_824)
  }

  func testEveryKeyIsRequired() throws {
    // The complete environment must cover exactly the canonical key set.
    let env = completeEnvironment()
    for key in BrokerConfigKey.allCases {
      XCTAssertNotNil(env[key.rawValue], "completeEnvironment is missing \(key.rawValue)")
    }
  }

  func testMissingKeysAreAllReported() {
    var env = completeEnvironment()
    env.removeValue(forKey: BrokerConfigKey.port.rawValue)
    env.removeValue(forKey: BrokerConfigKey.dataDir.rawValue)
    XCTAssertThrowsError(try config(env)) { error in
      guard let configError = error as? BrokerConfigError else {
        return XCTFail("expected BrokerConfigError, got \(error)")
      }
      let keys = Set(configError.problems.map(\.key))
      XCTAssertTrue(keys.contains(.port))
      XCTAssertTrue(keys.contains(.dataDir))
    }
  }

  func testUnparseableIntIsReportedWithRawValue() {
    var env = completeEnvironment()
    env[BrokerConfigKey.port.rawValue] = "not-a-number"
    XCTAssertThrowsError(try config(env)) { error in
      guard let configError = error as? BrokerConfigError else {
        return XCTFail("expected BrokerConfigError, got \(error)")
      }
      let portProblem = configError.problems.first { $0.key == .port }
      XCTAssertNotNil(portProblem)
      XCTAssertEqual(portProblem?.raw, "not-a-number")
    }
  }

  func testConcurrencyRejectsZeroAndNegative() {
    for badValue in ["0", "-1"] {
      var env = completeEnvironment()
      env[BrokerConfigKey.embeddingMaxConcurrency.rawValue] = badValue
      XCTAssertThrowsError(try config(env), "expected \(badValue) to be rejected") { error in
        let keys = ((error as? BrokerConfigError)?.problems.map(\.key)) ?? []
        XCTAssertTrue(keys.contains(.embeddingMaxConcurrency))
      }
    }
  }

  func testHostAllowlistRejectsOtherHosts() {
    var env = completeEnvironment()
    env[BrokerConfigKey.host.rawValue] = "0.0.0.0"
    XCTAssertThrowsError(try config(env)) { error in
      let keys = ((error as? BrokerConfigError)?.problems.map(\.key)) ?? []
      XCTAssertTrue(keys.contains(.host))
    }
  }

  func testPromptCacheBlankMeansAuto() throws {
    let config = try config(completeEnvironment())
    XCTAssertNil(config.promptCacheMaxTokens)
    XCTAssertNil(config.effectivePromptCacheMaxTokens)
  }

  func testPromptCacheDisabledImposesCeiling() throws {
    var env = completeEnvironment()
    env[BrokerConfigKey.promptCacheEnabled.rawValue] = "false"
    let config = try config(env)
    XCTAssertFalse(config.promptCacheEnabled)
    XCTAssertEqual(config.effectivePromptCacheMaxTokens, 8192)
  }

  func testPromptCacheExplicitValueWins() throws {
    var env = completeEnvironment()
    env[BrokerConfigKey.promptCacheMaxTokens.rawValue] = "4096"
    let config = try config(env)
    XCTAssertEqual(config.promptCacheMaxTokens, 4096)
    XCTAssertEqual(config.effectivePromptCacheMaxTokens, 4096)
  }

  func testBlankRequiredKeyIsRejected() {
    var env = completeEnvironment()
    env[BrokerConfigKey.dataDir.rawValue] = ""
    XCTAssertThrowsError(try config(env)) { error in
      let keys = ((error as? BrokerConfigError)?.problems.map(\.key)) ?? []
      XCTAssertTrue(keys.contains(.dataDir))
    }
  }
}
