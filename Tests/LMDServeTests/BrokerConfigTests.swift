//
//  BrokerConfigTests.swift
//  LMDServeTests
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-06-05.
//  Copyright © 2026, all rights reserved.
//

import Foundation
import Nimble
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
    env[BrokerConfigKey.embedBatchTokenBudget.rawValue] = ""
    env[BrokerConfigKey.embedBatchMaxRows.rawValue] = "256"
    env[BrokerConfigKey.embedPriorityMaxInputs.rawValue] = "2"
    env[BrokerConfigKey.embedPriorityMaxTokens.rawValue] = "2048"
    env[BrokerConfigKey.embedPriorityLane.rawValue] = "true"
    env[BrokerConfigKey.batteryThrottlePct.rawValue] = "20"
    env[BrokerConfigKey.batteryMildPct.rawValue] = "35"
    env[BrokerConfigKey.batteryResumePct.rawValue] = "80"
    env[BrokerConfigKey.batteryHighPowerOverride.rawValue] = "true"
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

  private func fixtureSource(
    overrides: [BrokerConfigKey: String] = [:],
    removing removedKeys: [BrokerConfigKey] = []
  ) -> BrokerConfigSource {
    var env = completeEnvironment()
    for (key, value) in overrides {
      env[key.rawValue] = value
    }
    for key in removedKeys {
      env.removeValue(forKey: key.rawValue)
    }
    return EnvironmentConfigSource(environment: env)
  }

  private func config(_ env: [String: String]) throws -> BrokerConfig {
    try BrokerConfig(source: EnvironmentConfigSource(environment: env))
  }

  private func expectConfigError(
    _ env: [String: String],
    _ assertions: (BrokerConfigError) -> Void
  ) {
    do {
      _ = try config(env)
      fail("expected BrokerConfigError")
    } catch let error as BrokerConfigError {
      assertions(error)
    } catch {
      fail("expected BrokerConfigError, got \(error)")
    }
  }

  func testCompleteConfigParses() throws {
    let config = try config(completeEnvironment())
    expect(config.host) == "localhost"
    expect(config.bindHost) == "::1"
    expect(config.port) == 5_400
    expect(config.reserveBytes) == 20 * 1_073_741_824
    expect(config.swiftlmBinary) == "/usr/bin/true"
    expect(config.chatMaxConcurrency) == 4
    expect(config.embeddingMaxConcurrency) == 4
    expect(config.embedBatchTokenBudget) == nil
    expect(config.embedBatchMaxRows) == 256
    expect(config.embedPriorityMaxInputs) == 2
    expect(config.embedPriorityMaxTokens) == 2_048
    expect(config.embedPriorityLaneEnabled) == true
    expect(config.batteryThrottlePct) == 20
    expect(config.batteryMildPct) == 35
    expect(config.batteryResumePct) == 80
    expect(config.batteryHighPowerOverride) == true
    expect(config.disableXPC) == false
    expect(config.idleMinutes) == 15
    expect(config.embeddingIdleMinutes) == 60
    expect(config.dataDir) == "/tmp"
    expect(config.sampleInterval) == (expected: 15, delta: 0.0001)
    expect(config.promptCacheEnabled) == true
    expect(config.promptCacheMaxTokens) == nil
    expect(config.mlxCacheLimitGB) == 2.0
  }

  func testEmbedKnobsParseExplicitValues() throws {
    let config = try BrokerConfig(
      source: fixtureSource(overrides: [
        .embedBatchTokenBudget: "8192",
        .embedBatchMaxRows: "128",
        .embedPriorityMaxInputs: "4",
        .embedPriorityMaxTokens: "1024",
        .embedPriorityLane: "false",
        .mlxCacheLimitGB: "4",
      ]))
    expect(config.embedBatchTokenBudget) == 8_192
    expect(config.embedBatchMaxRows) == 128
    expect(config.embedPriorityMaxInputs) == 4
    expect(config.embedPriorityMaxTokens) == 1_024
    expect(config.embedPriorityLaneEnabled) == false
    expect(config.mlxCacheLimitGB) == 4.0
  }

  func testEmbedBudgetAndCacheBlankMeansAuto() throws {
    let config = try BrokerConfig(
      source: fixtureSource(overrides: [
        .embedBatchTokenBudget: "",
        .mlxCacheLimitGB: "",
      ]))
    expect(config.embedBatchTokenBudget).to(beNil())
    expect(config.mlxCacheLimitGB).to(beNil())
  }

  func testEmbedKnobsMissingKeyFailsNamingTheKey() {
    expect {
      try BrokerConfig(source: self.fixtureSource(removing: [.embedBatchMaxRows]))
    }.to(
      throwError { (error: BrokerConfigError) in
        expect(error.problems.map(\.key)).to(contain(.embedBatchMaxRows))
      })
  }

  func testEveryKeyIsRequired() {
    // The complete environment must cover exactly the canonical key set.
    let env = completeEnvironment()
    for key in BrokerConfigKey.allCases {
      expect(env[key.rawValue]) != nil
    }
  }

  func testMissingKeysAreAllReported() {
    var env = completeEnvironment()
    env.removeValue(forKey: BrokerConfigKey.port.rawValue)
    env.removeValue(forKey: BrokerConfigKey.dataDir.rawValue)
    expectConfigError(env) { configError in
      let keys = Set(configError.problems.map(\.key))
      expect(keys.contains(.port)) == true
      expect(keys.contains(.dataDir)) == true
    }
  }

  func testUnparseableIntIsReportedWithRawValue() {
    var env = completeEnvironment()
    env[BrokerConfigKey.port.rawValue] = "not-a-number"
    expectConfigError(env) { configError in
      let portProblem = configError.problems.first { $0.key == .port }
      expect(portProblem) != nil
      expect(portProblem?.raw) == "not-a-number"
    }
  }

  func testConcurrencyRejectsZeroAndNegative() {
    for badValue in ["0", "-1"] {
      var env = completeEnvironment()
      env[BrokerConfigKey.embeddingMaxConcurrency.rawValue] = badValue
      expectConfigError(env) { configError in
        let keys = configError.problems.map(\.key)
        expect(keys.contains(.embeddingMaxConcurrency)) == true
      }
    }
  }

  func testMildPctMustBeAboveThrottlePct() {
    var env = completeEnvironment()
    env[BrokerConfigKey.batteryThrottlePct.rawValue] = "40"
    env[BrokerConfigKey.batteryMildPct.rawValue] = "35"
    expectConfigError(env) { configError in
      let keys = configError.problems.map(\.key)
      expect(keys.contains(.batteryMildPct)) == true
    }
  }

  func testMildPctMustBeBelowResumePct() {
    var env = completeEnvironment()
    env[BrokerConfigKey.batteryMildPct.rawValue] = "85"
    env[BrokerConfigKey.batteryResumePct.rawValue] = "80"
    expectConfigError(env) { configError in
      let keys = configError.problems.map(\.key)
      expect(keys.contains(.batteryMildPct)) == true
    }
  }

  func testHostAllowlistRejectsOtherHosts() {
    var env = completeEnvironment()
    env[BrokerConfigKey.host.rawValue] = "0.0.0.0"
    expectConfigError(env) { configError in
      let keys = configError.problems.map(\.key)
      expect(keys.contains(.host)) == true
    }
  }

  func testPromptCacheBlankMeansAuto() throws {
    let config = try config(completeEnvironment())
    expect(config.promptCacheMaxTokens) == nil
    expect(config.effectivePromptCacheMaxTokens) == nil
  }

  func testPromptCacheDisabledImposesCeiling() throws {
    var env = completeEnvironment()
    env[BrokerConfigKey.promptCacheEnabled.rawValue] = "false"
    let config = try config(env)
    expect(config.promptCacheEnabled) == false
    expect(config.effectivePromptCacheMaxTokens) == 8_192
  }

  func testPromptCacheExplicitValueWins() throws {
    var env = completeEnvironment()
    env[BrokerConfigKey.promptCacheMaxTokens.rawValue] = "4096"
    let config = try config(env)
    expect(config.promptCacheMaxTokens) == 4_096
    expect(config.effectivePromptCacheMaxTokens) == 4_096
  }

  func testBlankRequiredKeyIsRejected() {
    var env = completeEnvironment()
    env[BrokerConfigKey.dataDir.rawValue] = ""
    expectConfigError(env) { configError in
      let keys = configError.problems.map(\.key)
      expect(keys.contains(.dataDir)) == true
    }
  }
}
