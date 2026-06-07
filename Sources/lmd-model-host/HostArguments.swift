//
//  HostArguments.swift
//  lmd-model-host
//
//  Parses the broker-supplied argv for a model host child. The spawn token is
//  NOT here: it arrives on stdin, a private parent-to-child pipe.
//

import Foundation
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

  /// Parse `--model <path> --kind <chat|embedding|video> --host-service <name>`
  /// plus the optional `--video-sampling-fps <double>`. Returns nil when any
  /// required field is missing or the kind is unrecognized.
  static func parse(_ argv: [String]) -> HostArguments? {
    var model: String?
    var kindRaw: String?
    var service: String?
    var swiftLMBinaryPath: String?
    var swiftLMLogPath: String?
    var contextLength: Int?
    var videoSamplingFPS: Double?
    var index = 0
    while index + 1 < argv.count {
      switch argv[index] {
      case "--model": model = argv[index + 1]
      case "--kind": kindRaw = argv[index + 1]
      case "--host-service": service = argv[index + 1]
      case "--swiftlm-binary": swiftLMBinaryPath = argv[index + 1]
      case "--swiftlm-log-path": swiftLMLogPath = argv[index + 1]
      case "--context-length": contextLength = Int(argv[index + 1])
      case "--video-sampling-fps": videoSamplingFPS = Double(argv[index + 1])
      default: break
      }
      index += 2
    }
    guard let model, let kindRaw, let service, let kind = BackendKind(rawValue: kindRaw) else {
      return nil
    }
    return HostArguments(
      modelPath: model,
      kind: kind,
      hostService: service,
      swiftLMBinaryPath: swiftLMBinaryPath,
      swiftLMLogPath: swiftLMLogPath,
      contextLength: contextLength,
      videoSamplingFPS: videoSamplingFPS
    )
  }
}
