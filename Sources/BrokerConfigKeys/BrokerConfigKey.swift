//
//  BrokerConfigKey.swift
//  BrokerConfigKeys
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-07-19.
//  Copyright © 2026, all rights reserved.
//
//  The canonical registry of broker configuration keys, plus the single default
//  environment used by every programmatically spawned broker (the smoke harness
//  and the config tests). Production still sources its values from the launchd
//  plist; this module owns the values only for brokers spawned in code, so a key
//  added to `BrokerConfigKey` forces a matching default in
//  `defaultBrokerEnvironment` at compile time and the spawned env can never drift
//  back out of the required set.
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

// MARK: - Default environment

/// A complete broker environment covering every `BrokerConfigKey`, suitable for
/// spawning `lmd-serve` in a child process. Each `overrides` entry replaces one
/// key; every other key takes its default from the exhaustive switch in
/// `defaultBrokerConfigValue(for:)`, so adding a case to `BrokerConfigKey` fails
/// to compile until it has a default here.
///
/// These values match the launchd plist's shape but are chosen for in-code
/// spawning: `swiftlmBinary` defaults to `/usr/bin/true` so the broker's boot
/// executable check passes without a real SwiftLM install, and callers that need
/// a live binary or a different port, host, or data dir pass them through
/// `overrides`.
public func defaultBrokerEnvironment(
  overrides: [BrokerConfigKey: String] = [:]
) -> [String: String] {
  var environment: [String: String] = [:]
  for key in BrokerConfigKey.allCases {
    if let override = overrides[key] {
      environment[key.rawValue] = override
    } else {
      environment[key.rawValue] = defaultBrokerConfigValue(for: key)
    }
  }
  return environment
}

/// The default string value for one configuration key. A blank string is the
/// explicit "auto" request for the auto-capable keys (`embedBatchTokenBudget`,
/// `promptCacheMaxTokens`, `mlxCacheLimitGB`), which `BrokerConfig` accepts.
private func defaultBrokerConfigValue(for key: BrokerConfigKey) -> String {
  switch key {
  case .host:
    return "localhost"
  case .port:
    return "5400"
  case .reserveGB:
    return "20"
  case .swiftlmBinary:
    return "/usr/bin/true"
  case .chatMaxConcurrency:
    return "4"
  case .embeddingMaxConcurrency:
    return "4"
  case .embedBatchTokenBudget:
    return ""
  case .embedBatchMaxRows:
    return "256"
  case .embedPriorityMaxInputs:
    return "2"
  case .embedPriorityMaxTokens:
    return "2048"
  case .embedPriorityLane:
    return "true"
  case .batteryThrottlePct:
    return "20"
  case .batteryMildPct:
    return "35"
  case .batteryResumePct:
    return "80"
  case .batteryHighPowerOverride:
    return "true"
  case .disableXPC:
    return "0"
  case .idleMinutes:
    return "15"
  case .embeddingIdleMinutes:
    return "60"
  case .dataDir:
    return "/tmp"
  case .sampleInterval:
    return "15"
  case .promptCacheMaxTokens:
    return ""
  case .promptCacheEnabled:
    return "true"
  case .mlxCacheLimitGB:
    return "2"
  }
}
