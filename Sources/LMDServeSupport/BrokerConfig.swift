//
//  BrokerConfig.swift
//  LMDServeSupport
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-06-05.
//  Copyright © 2026, all rights reserved.
//
//  One typed boundary for every broker configuration value. The broker reads
//  configuration exactly once, here, through a `BrokerConfigSource`. No other
//  startup code reads `ProcessInfo.processInfo.environment` for configuration,
//  so replacing the env-backed source with a file-backed one later is a single
//  change at the construction site in `SwiftLMD.main`.
//
//  There are no silent fallbacks: every key must be present and parseable, and
//  a load failure names every offending key at once so the operator can fix the
//  plist in a single pass.
//

import Foundation

// MARK: - Keys

/// Every broker configuration variable, declared once. `allCases` is the
/// canonical list that the deploy plist and `docs/configuration.md` are checked
/// against, so a key added in one place but not the others is caught rather
/// than silently drifting.
///
/// `LMD_TRACE_DISABLE_MLX_SNAPSHOT` is intentionally absent: it is a
/// diagnostic/test switch read at static initialization in `SwiftLMTrace`,
/// normally unset in production, and set directly by unit tests that never
/// construct a `BrokerConfig`. It is documented under diagnostics, not here.
/// `XPC_SERVICE_NAME` is also absent: launchd provides it as process identity,
/// it is not operator configuration.
public enum BrokerConfigKey: String, CaseIterable, Sendable {
  case batteryHighPowerOverride = "LMD_BATTERY_HIGHPOWER_OVERRIDE"
  case batteryMildPct = "LMD_BATTERY_MILD_PCT"
  case batteryResumePct = "LMD_BATTERY_RESUME_PCT"
  case batteryThrottlePct = "LMD_BATTERY_THROTTLE_PCT"
  case chatMaxConcurrency = "LMD_CHAT_MAX_CONCURRENCY"
  case dataDir = "LMD_DATA_DIR"
  case disableXPC = "LMD_DISABLE_XPC"
  case embedBatchMaxRows = "LMD_EMBED_BATCH_MAX_ROWS"
  case embedBatchTokenBudget = "LMD_EMBED_BATCH_TOKEN_BUDGET"
  case embeddingIdleMinutes = "LMD_EMBEDDING_IDLE_MINUTES"
  case embeddingMaxConcurrency = "LMD_EMBEDDING_MAX_CONCURRENCY"
  case embedPriorityLane = "LMD_EMBED_PRIORITY_LANE"
  case embedPriorityMaxInputs = "LMD_EMBED_PRIORITY_MAX_INPUTS"
  case embedPriorityMaxTokens = "LMD_EMBED_PRIORITY_MAX_TOKENS"
  case host = "LMD_HOST"
  case idleMinutes = "LMD_IDLE_MINUTES"
  case mlxCacheLimitGB = "LMD_MLX_CACHE_LIMIT_GB"
  case port = "LMD_PORT"
  case promptCacheEnabled = "LMD_PROMPT_CACHE_ENABLED"
  case promptCacheMaxTokens = "LMD_PROMPT_CACHE_MAX_TOKENS"
  case reserveGB = "LMD_RESERVE_GB"
  case sampleInterval = "LMD_SAMPLE_INTERVAL"
  case swiftlmBinary = "LMD_SWIFTLM_BINARY"
}

// MARK: - Source

/// Supplies the raw string for a configuration key. The default reads the
/// process environment populated by the launchd plist. A future file-backed
/// source conforms to the same protocol; switching is one line where the source
/// is constructed.
///
/// `raw` returns `nil` only when the key is genuinely absent. A present but
/// empty value is returned as the empty string so the loader can distinguish
/// "undefined" (an error) from "defined as blank" (meaningful for
/// auto-capable keys such as `promptCacheMaxTokens`).
public protocol BrokerConfigSource: Sendable {
  func raw(_ key: BrokerConfigKey) -> String?
}

/// Reads configuration from a process environment dictionary.
public struct EnvironmentConfigSource: BrokerConfigSource {
  private let environment: [String: String]

  public init(environment: [String: String] = ProcessInfo.processInfo.environment) {
    self.environment = environment
  }

  public func raw(_ key: BrokerConfigKey) -> String? {
    environment[key.rawValue]
  }
}

// MARK: - Error

/// Aggregated configuration failure. Carries one problem per offending key so
/// the broker can report every missing or invalid value in a single startup
/// error rather than failing one key at a time.
public struct BrokerConfigError: Error, CustomStringConvertible {
  public struct Problem: Sendable {
    public let key: BrokerConfigKey
    public let raw: String?
    public let reason: String
  }

  public let problems: [Problem]

  public var description: String {
    let lines = problems.map { problem -> String in
      let shown = problem.raw.map { "\"\($0)\"" } ?? "<undefined>"
      return "  \(problem.key.rawValue) (\(shown)): \(problem.reason)"
    }
    return "broker configuration is invalid:\n" + lines.joined(separator: "\n")
  }
}

// MARK: - Config

/// The fully resolved, typed broker configuration. Built once at startup from a
/// `BrokerConfigSource`; every field is concrete and validated.
public struct BrokerConfig: Sendable {
  public let host: String
  public let bindHost: String
  public let port: Int
  public let reserveBytes: Int64
  public let swiftlmBinary: String
  public let chatMaxConcurrency: Int
  public let embeddingMaxConcurrency: Int
  /// nil means auto: the broker sizes the budget from the resolved cache cap at
  /// embedding-host spawn time. Blank LMD_EMBED_BATCH_TOKEN_BUDGET requests auto.
  public let embedBatchTokenBudget: Int?
  public let embedBatchMaxRows: Int
  public let embedPriorityMaxInputs: Int
  public let embedPriorityMaxTokens: Int
  public let embedPriorityLaneEnabled: Bool
  /// nil means auto: the broker sizes the cache from free memory at startup and
  /// at embedding-host spawn time. Blank LMD_MLX_CACHE_LIMIT_GB requests auto.
  public let mlxCacheLimitGB: Double?
  public let batteryThrottlePct: Int
  public let batteryMildPct: Int
  public let batteryResumePct: Int
  /// When true, AC power in High Power energy mode lifts the battery hard stop.
  public let batteryHighPowerOverride: Bool
  public let disableXPC: Bool
  public let idleMinutes: Int
  public let embeddingIdleMinutes: Int
  public let dataDir: String
  public let sampleInterval: Double
  public let promptCacheEnabled: Bool
  /// `nil` means "auto" (the broker chooses), defined explicitly by leaving
  /// `LMD_PROMPT_CACHE_MAX_TOKENS` blank in the plist.
  public let promptCacheMaxTokens: Int?

  private static let gigabyte: Int64 = 1_073_741_824
  /// Conservative prompt-token ceiling used when the prompt cache is disabled
  /// and no explicit limit is set, mirroring the prior inline behavior.
  private static let disabledPromptCacheCeiling = 8_192

  /// The prompt-token ceiling enforced before admitting a chat request. An
  /// explicit `promptCacheMaxTokens` wins; otherwise a disabled cache imposes a
  /// conservative ceiling and an enabled cache imposes none.
  public var effectivePromptCacheMaxTokens: Int? {
    if let promptCacheMaxTokens {
      return promptCacheMaxTokens
    }
    return promptCacheEnabled ? nil : Self.disabledPromptCacheCeiling
  }

  public init(source: BrokerConfigSource) throws {
    var problems: [BrokerConfigError.Problem] = []

    func record(_ key: BrokerConfigKey, _ raw: String?, _ reason: String) {
      problems.append(.init(key: key, raw: raw, reason: reason))
    }

    // A required, non-empty string.
    func requireString(_ key: BrokerConfigKey) -> String? {
      guard let value = source.raw(key) else {
        record(key, nil, "must be defined")
        return nil
      }
      if value.isEmpty {
        record(key, value, "must not be empty")
        return nil
      }
      return value
    }

    func requireInt(_ key: BrokerConfigKey, min: Int? = nil, max: Int? = nil) -> Int? {
      guard let text = requireString(key) else {
        return nil
      }
      guard let value = Int(text) else {
        record(key, text, "must be an integer")
        return nil
      }
      if let min, value < min {
        record(key, text, "must be >= \(min)")
        return nil
      }
      if let max, value > max {
        record(key, text, "must be <= \(max)")
        return nil
      }
      return value
    }

    func requireDouble(_ key: BrokerConfigKey, min: Double? = nil) -> Double? {
      guard let text = requireString(key) else {
        return nil
      }
      guard let value = Double(text) else {
        record(key, text, "must be a number")
        return nil
      }
      if let min, value < min {
        record(key, text, "must be >= \(min)")
        return nil
      }
      return value
    }

    func requireBool(_ key: BrokerConfigKey) -> Bool? {
      guard let text = requireString(key) else {
        return nil
      }
      switch text.lowercased() {
      case "1", "true", "yes", "on":
        return true
      case "0", "false", "no", "off":
        return false
      default:
        record(key, text, "must be a boolean (1/0, true/false, yes/no, on/off)")
        return nil
      }
    }

    let hostValue = requireString(.host)
    let portValue = requireInt(.port, min: 1, max: 65_535)
    var resolvedHost = ""
    var resolvedBindHost = "::1"
    if let hostValue {
      switch hostValue {
      case "localhost", "[::1]":
        resolvedHost = hostValue
        resolvedBindHost = "::1"
      default:
        record(.host, hostValue, "must be localhost or [::1]")
      }
    }

    let reserveGB = requireInt(.reserveGB, min: 0)
    let swiftlmBinary = requireString(.swiftlmBinary)
    let chatConcurrency = requireInt(.chatMaxConcurrency, min: 1)
    let embeddingConcurrency = requireInt(.embeddingMaxConcurrency, min: 1)
    let embedMaxRowsValue = requireInt(.embedBatchMaxRows, min: 1)
    let embedPriorityInputsValue = requireInt(.embedPriorityMaxInputs, min: 0)
    let embedPriorityTokensValue = requireInt(.embedPriorityMaxTokens, min: 0)
    let embedPriorityLaneValue = requireBool(.embedPriorityLane)
    let throttlePct = requireInt(.batteryThrottlePct, min: 0, max: 100)
    let mildPct = requireInt(.batteryMildPct, min: 0, max: 100)
    let resumePct = requireInt(.batteryResumePct, min: 0, max: 100)
    // The mild band must sit above the hard stop and below the resume point, so
    // the levels stay ordered: hard <= mild <= resume with both gaps non-empty.
    if let throttlePct, let mildPct, mildPct <= throttlePct {
      record(
        .batteryMildPct, String(mildPct),
        "must be greater than LMD_BATTERY_THROTTLE_PCT (\(throttlePct))")
    }
    if let mildPct, let resumePct, mildPct >= resumePct {
      record(
        .batteryMildPct, String(mildPct),
        "must be less than LMD_BATTERY_RESUME_PCT (\(resumePct))")
    }
    let batteryHighPowerOverrideValue = requireBool(.batteryHighPowerOverride)
    let disableXPC = requireBool(.disableXPC)
    let idleMinutes = requireInt(.idleMinutes, min: 0)
    let embeddingIdleMinutes = requireInt(.embeddingIdleMinutes, min: 0)
    let dataDir = requireString(.dataDir)
    let sampleInterval = requireDouble(.sampleInterval, min: 0.1)
    let promptCacheEnabled = requireBool(.promptCacheEnabled)

    // An auto-capable key must be defined (present), but a blank value is the
    // explicit way to request "auto" (nil). An unparseable value records a
    // problem; the recorded problem fails the init, so the nil it returns is
    // never read as auto.
    func autoOrParsed<Value>(
      _ key: BrokerConfigKey,
      reason: String,
      parse: (String) -> Value?
    ) -> Value? {
      guard let raw = source.raw(key) else {
        record(key, nil, "must be defined (blank means auto)")
        return nil
      }
      if raw.isEmpty {
        return nil
      }
      guard let parsed = parse(raw) else {
        record(key, raw, reason)
        return nil
      }
      return parsed
    }

    func positiveInt(_ text: String) -> Int? {
      guard let value = Int(text), value > 0 else {
        return nil
      }
      return value
    }

    func positiveDouble(_ text: String) -> Double? {
      guard let value = Double(text), value > 0 else {
        return nil
      }
      return value
    }

    let embedBatchTokenBudgetValue = autoOrParsed(
      .embedBatchTokenBudget,
      reason: "must be a positive integer or blank for auto",
      parse: positiveInt)
    let promptCacheMaxTokensValue = autoOrParsed(
      .promptCacheMaxTokens,
      reason: "must be a positive integer or blank for auto",
      parse: positiveInt)
    let mlxCacheLimitGBValue = autoOrParsed(
      .mlxCacheLimitGB,
      reason: "must be a positive number or blank for auto",
      parse: positiveDouble)

    guard problems.isEmpty,
      let portValue,
      let reserveGB,
      let swiftlmBinary,
      let chatConcurrency,
      let embeddingConcurrency,
      let embedMaxRowsValue,
      let embedPriorityInputsValue,
      let embedPriorityTokensValue,
      let embedPriorityLaneValue,
      let throttlePct,
      let mildPct,
      let resumePct,
      let batteryHighPowerOverrideValue,
      let disableXPC,
      let idleMinutes,
      let embeddingIdleMinutes,
      let dataDir,
      let sampleInterval,
      let promptCacheEnabled
    else {
      throw BrokerConfigError(problems: problems)
    }

    self.host = resolvedHost
    self.bindHost = resolvedBindHost
    self.port = portValue
    self.reserveBytes = Int64(reserveGB) * Self.gigabyte
    self.swiftlmBinary = swiftlmBinary
    self.chatMaxConcurrency = chatConcurrency
    self.embeddingMaxConcurrency = embeddingConcurrency
    self.embedBatchTokenBudget = embedBatchTokenBudgetValue
    self.embedBatchMaxRows = embedMaxRowsValue
    self.embedPriorityMaxInputs = embedPriorityInputsValue
    self.embedPriorityMaxTokens = embedPriorityTokensValue
    self.embedPriorityLaneEnabled = embedPriorityLaneValue
    self.mlxCacheLimitGB = mlxCacheLimitGBValue
    self.batteryThrottlePct = throttlePct
    self.batteryMildPct = mildPct
    self.batteryResumePct = resumePct
    self.batteryHighPowerOverride = batteryHighPowerOverrideValue
    self.disableXPC = disableXPC
    self.idleMinutes = idleMinutes
    self.embeddingIdleMinutes = embeddingIdleMinutes
    self.dataDir = dataDir
    self.sampleInterval = sampleInterval
    self.promptCacheEnabled = promptCacheEnabled
    self.promptCacheMaxTokens = promptCacheMaxTokensValue
  }
}
