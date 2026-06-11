//
//  HostArguments.swift
//  lmd-model-host
//
//  Parses the broker-supplied argv for a model host child. The spawn token is
//  NOT here: it arrives on stdin, a private parent-to-child pipe.
//

import Foundation
import SwiftLMEmbed
import SwiftLMHostProtocol

struct HostArguments: Equatable {
  let modelPath: String
  let kind: BackendKind
  let hostService: String
  /// Absolute path to the SwiftLM binary. Required only for chat hosts.
  let swiftLMBinaryPath: String?
  /// Optional file path where SwiftLM child stdout and stderr are appended.
  let swiftLMLogPath: String?
  /// Optional context length forwarded to the SwiftLM child for chat hosts.
  let contextLength: Int?
  /// Frame rate the model's preprocessor expects when given pre-sampled video
  /// frames. The broker knows this from the model descriptor's capabilities and
  /// passes it so the video host samples at the same rate the in-process backend
  /// did. nil for non-video kinds or a video model with no detected rate.
  let videoSamplingFPS: Double?
  let mlxCacheLimitBytes: Int?
  let embedSlotBudget: Int?
  let embedMaxRows: Int?
  let embedPriorityMaxInputs: Int?
  let embedPriorityMaxTokens: Int?
  /// The priority-lane switch carried by `--embed-priority-lane`. A host
  /// launched without the flag runs with the fallback (lane enabled), the same
  /// value the broker sends by default, so absence and default agree.
  let embedPriorityLane: Bool
  let embedMaxForwards: Int?

  /// Parse the required host fields plus optional chat, video, and embedding
  /// tuning flags. Returns nil when any required field is missing or the kind is
  /// unrecognized.
  static func parse(_ argv: [String]) -> HostArguments? {
    var parsedModel: String?
    var parsedKindRaw: String?
    var parsedService: String?
    var parsedSwiftLMBinaryPath: String?
    var parsedSwiftLMLogPath: String?
    var parsedContextLength: Int?
    var parsedVideoSamplingFPS: Double?
    var parsedMlxCacheLimitBytes: Int?
    var parsedEmbedSlotBudget: Int?
    var parsedEmbedMaxRows: Int?
    var parsedEmbedPriorityMaxInputs: Int?
    var parsedEmbedPriorityMaxTokens: Int?
    var parsedEmbedPriorityLane = EmbeddingRuntimeTuning.fallback.priorityLaneEnabled
    var parsedEmbedMaxForwards: Int?
    var index = 0
    while index + 1 < argv.count {
      switch argv[index] {
      case "--model": parsedModel = argv[index + 1]
      case "--kind": parsedKindRaw = argv[index + 1]
      case "--host-service": parsedService = argv[index + 1]
      case "--swiftlm-binary": parsedSwiftLMBinaryPath = argv[index + 1]
      case "--swiftlm-log-path": parsedSwiftLMLogPath = argv[index + 1]
      case "--context-length": parsedContextLength = Int(argv[index + 1])
      case "--video-sampling-fps": parsedVideoSamplingFPS = Double(argv[index + 1])
      case "--mlx-cache-limit-bytes": parsedMlxCacheLimitBytes = Int(argv[index + 1])
      case "--embed-slot-budget": parsedEmbedSlotBudget = Int(argv[index + 1])
      case "--embed-max-rows": parsedEmbedMaxRows = Int(argv[index + 1])
      case "--embed-priority-max-inputs": parsedEmbedPriorityMaxInputs = Int(argv[index + 1])
      case "--embed-priority-max-tokens": parsedEmbedPriorityMaxTokens = Int(argv[index + 1])
      case "--embed-priority-lane": parsedEmbedPriorityLane = argv[index + 1] == "1"
      case "--embed-max-forwards": parsedEmbedMaxForwards = Int(argv[index + 1])
      default: break
      }
      index += 2
    }
    guard let parsedModel, let parsedKindRaw, let parsedService,
      let parsedKind = BackendKind(rawValue: parsedKindRaw)
    else {
      return nil
    }
    return HostArguments(
      modelPath: parsedModel,
      kind: parsedKind,
      hostService: parsedService,
      swiftLMBinaryPath: parsedSwiftLMBinaryPath,
      swiftLMLogPath: parsedSwiftLMLogPath,
      contextLength: parsedContextLength,
      videoSamplingFPS: parsedVideoSamplingFPS,
      mlxCacheLimitBytes: parsedMlxCacheLimitBytes,
      embedSlotBudget: parsedEmbedSlotBudget,
      embedMaxRows: parsedEmbedMaxRows,
      embedPriorityMaxInputs: parsedEmbedPriorityMaxInputs,
      embedPriorityMaxTokens: parsedEmbedPriorityMaxTokens,
      embedPriorityLane: parsedEmbedPriorityLane,
      embedMaxForwards: parsedEmbedMaxForwards
    )
  }

  /// The tuning the embedding backend and queue consume. Fallback values cover
  /// a host launched without tuning flags (tests, manual runs).
  func embeddingRuntimeTuning() -> EmbeddingRuntimeTuning {
    EmbeddingRuntimeTuning(
      slotBudget: embedSlotBudget ?? EmbeddingRuntimeTuning.fallback.slotBudget,
      maxRows: embedMaxRows ?? EmbeddingRuntimeTuning.fallback.maxRows,
      priorityMaxInputs: embedPriorityMaxInputs
        ?? EmbeddingRuntimeTuning.fallback.priorityMaxInputs,
      priorityMaxTokens: embedPriorityMaxTokens
        ?? EmbeddingRuntimeTuning.fallback.priorityMaxTokens,
      priorityLaneEnabled: embedPriorityLane,
      maxConcurrentForwards: embedMaxForwards
        ?? EmbeddingRuntimeTuning.fallback.maxConcurrentForwards
    )
  }
}
