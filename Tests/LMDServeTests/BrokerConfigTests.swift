//
//  BrokerConfigTests.swift
//  LMDServeTests
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-06-05.
//  Copyright © 2026, all rights reserved.
//

import BrokerConfigKeys
import Foundation
import Nimble
import XCTest

@testable import LMDServeSupport

final class BrokerConfigTests: XCTestCase {
  /// A complete, valid environment for every key. Tests mutate a copy to
  /// exercise individual failures. This is the shared `defaultBrokerEnvironment`
  /// the smoke harness spawns the broker with, so a value that stops parsing here
  /// stops the smoke run too.
  private func completeEnvironment() -> [String: String] {
    defaultBrokerEnvironment()
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

  func testDefaultBrokerEnvironmentParsesEndToEnd() throws {
    // The single source of truth the smoke harness spawns with must satisfy the
    // parser without any overrides, so a default that drifts out of range fails
    // here before it fails a smoke run with an opaque EX_CONFIG exit.
    let environment = defaultBrokerEnvironment()
    for key in BrokerConfigKey.allCases {
      expect(environment[key.rawValue]) != nil
    }
    _ = try BrokerConfig(source: EnvironmentConfigSource(environment: environment))
  }

  func testDefaultBrokerEnvironmentAppliesOverrides() {
    let environment = defaultBrokerEnvironment(overrides: [.port: "15999", .disableXPC: "1"])
    expect(environment[BrokerConfigKey.port.rawValue]) == "15999"
    expect(environment[BrokerConfigKey.disableXPC.rawValue]) == "1"
    expect(environment[BrokerConfigKey.host.rawValue]) == "localhost"
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
