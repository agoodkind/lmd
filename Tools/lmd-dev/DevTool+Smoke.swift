//
//  DevTool+Smoke.swift
//  lmd-dev
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-05-10.
//  Copyright © 2026, all rights reserved.
//

import Foundation
import SwiftMkCore

/// The lowest valid TCP port.
private let minimumPort = 1
/// The highest valid TCP port.
private let maximumPort = 65_535
/// The fixed port the smoke test uses against an already-running daemon.
private let runningDaemonPort = 5_400
/// The inclusive lower bound of the ephemeral smoke-test port range.
private let ephemeralPortRangeStart = 15_000
/// The exclusive upper bound of the ephemeral smoke-test port range.
private let ephemeralPortRangeEnd = 16_000
/// Default video acceptance request timeout, in seconds.
private let defaultVideoTimeoutSeconds: Double = 1_800
/// Default maximum tokens for the video acceptance request.
private let defaultVideoMaxTokens = 96
/// Frames-per-second the video acceptance request samples at.
private let videoSampleFPS: Double = 1
/// Maximum frames the video acceptance request samples.
private let videoSampleMaxFrames = 16
/// The `/health` poll interval, in seconds. Shared with the log-smoke pause.
let healthPollSeconds: TimeInterval = 1

// MARK: - HTTPResult

struct HTTPResult {
  let statusCode: Int
  let data: Data
}

// MARK: - SmokeConfiguration

struct SmokeConfiguration {
  let binaryDirectory: URL
  let host: String
  let port: Int
  let useRunningDaemon: Bool
  let videoModel: String
  let videoSampleFile: URL?
  let videoTimeoutSeconds: TimeInterval
  let videoMaxTokens: Int
  let baseURL: URL

  init(environment: [String: String], repoRoot: URL) throws {
    let binaryDirectoryPath = environment["LMD_BINARY_DIR"] ?? "Products/Build/Release"
    binaryDirectory =
      URL(fileURLWithPath: binaryDirectoryPath, relativeTo: repoRoot)
      .standardizedFileURL

    host = environment["LMD_HOST"] ?? "localhost"
    guard Self.isAllowedHost(host) else {
      throw ToolError.failure("LMD_HOST must be localhost or [::1], got \(host)")
    }

    useRunningDaemon = environment["LMD_SMOKE_USE_RUNNING_DAEMON"] == "1"
    if let portValue = environment["LMD_PORT"], !portValue.isEmpty {
      guard let parsedPort = Int(portValue), (minimumPort...maximumPort).contains(parsedPort) else {
        throw ToolError.failure(
          "LMD_PORT must be an integer from \(minimumPort) through \(maximumPort), got \(portValue)"
        )
      }
      port = parsedPort
    } else if useRunningDaemon {
      port = runningDaemonPort
    } else {
      port = Int.random(in: ephemeralPortRangeStart..<ephemeralPortRangeEnd)
    }

    videoModel = environment["LMD_VIDEO_MODEL"] ?? defaultVideoModel
    if let samplePath = environment["LMD_VIDEO_SAMPLE_FILE"], !samplePath.isEmpty {
      videoSampleFile = URL(fileURLWithPath: samplePath).standardizedFileURL
    } else {
      videoSampleFile = nil
    }

    videoTimeoutSeconds = try Self.parsePositiveDouble(
      environment["LMD_VIDEO_TIMEOUT_SECONDS"],
      defaultValue: defaultVideoTimeoutSeconds,
      variableName: "LMD_VIDEO_TIMEOUT_SECONDS"
    )
    videoMaxTokens = try Self.parsePositiveInt(
      environment["LMD_VIDEO_MAX_TOKENS"],
      defaultValue: defaultVideoMaxTokens,
      variableName: "LMD_VIDEO_MAX_TOKENS"
    )

    guard let resolvedBaseURL = URL(string: "http://\(host):\(port)") else {
      throw ToolError.failure("could not form smoke base URL for host \(host) port \(port)")
    }
    baseURL = resolvedBaseURL
  }

  private static func isAllowedHost(_ host: String) -> Bool {
    host == "localhost" || host == "[::1]"
  }

  private static func parsePositiveDouble(
    _ rawValue: String?,
    defaultValue: Double,
    variableName: String
  ) throws -> Double {
    guard let rawValue, !rawValue.isEmpty else {
      return defaultValue
    }
    guard let value = Double(rawValue), value > 0, value.isFinite else {
      throw ToolError.failure("\(variableName) must be greater than 0, got \(rawValue)")
    }
    return value
  }

  private static func parsePositiveInt(
    _ rawValue: String?,
    defaultValue: Int,
    variableName: String
  ) throws -> Int {
    guard let rawValue, !rawValue.isEmpty else {
      return defaultValue
    }
    guard let value = Int(rawValue), value > 0 else {
      throw ToolError.failure("\(variableName) must be an integer greater than 0, got \(rawValue)")
    }
    return value
  }
}

// MARK: - Response models

struct ModelsResponse: Decodable {
  let object: String
  let data: [ModelEntry]

  struct ModelEntry: Decodable {}
}

// MARK: - LoadedModelsResponse

struct LoadedModelsResponse: Decodable {
  let models: [LoadedModel]
  let allocatedGB: Double

  enum CodingKeys: String, CodingKey {
    case allocatedGB = "allocated_gb"
    case models
  }

  struct LoadedModel: Decodable {}
}

// MARK: - ChatCompletionResponse

struct ChatCompletionResponse: Decodable {
  let choices: [Choice]

  struct Choice: Decodable {
    let message: Message
  }

  struct Message: Decodable {
    let content: MessageContent
  }
}

// MARK: - MessageContent

enum MessageContent: Decodable {
  case empty
  case parts([ContentPart])
  case text(String)

  init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    do {
      self = .text(try container.decode(String.self))
      return
    } catch {
      Output.notice("MessageContent not a string, trying parts error=\(error)")
    }
    do {
      self = .parts(try container.decode([ContentPart].self))
      return
    } catch {
      Output.notice("MessageContent not parts, treating as empty error=\(error)")
    }
    self = .empty
  }

  var isNonEmpty: Bool {
    switch self {
    case .text(let text):
      return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    case .parts(let parts):
      return parts.contains { part in
        guard let text = part.text else {
          return false
        }
        return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      }
    case .empty:
      return false
    }
  }

  struct ContentPart: Decodable {
    let text: String?
  }
}

// MARK: - VideoChatRequest

struct VideoChatRequest: Encodable {
  let model: String
  let messages: [Message]
  let maxTokens: Int
  let temperature: Double

  enum CodingKeys: String, CodingKey {
    case maxTokens = "max_tokens"
    case messages
    case model
    case temperature
  }

  struct Message: Encodable {
    let role: String
    let content: [ContentPart]
  }

  struct ContentPart: Encodable {
    let type: String
    let text: String?
    let videoURL: VideoURL?

    enum CodingKeys: String, CodingKey {
      case text
      case type
      case videoURL = "video_url"
    }

    static func text(_ text: String) -> Self {
      Self(type: "text", text: text, videoURL: nil)
    }

    static func video(url: URL) -> Self {
      Self(
        type: "video_url",
        text: nil,
        videoURL: VideoURL(
          url: url.absoluteString, fps: videoSampleFPS, maxFrames: videoSampleMaxFrames)
      )
    }
  }

  struct VideoURL: Encodable {
    let url: String
    let fps: Double
    let maxFrames: Int

    enum CodingKeys: String, CodingKey {
      case fps
      case maxFrames = "max_frames"
      case url
    }
  }
}

// MARK: - Smoke entry points

extension DevTool {
  func smoke(requireVideo: Bool) async throws {
    Output.debug("smoke requireVideo=\(requireVideo)")
    let configuration = try SmokeConfiguration(environment: environment.values, repoRoot: repoRoot)
    if requireVideo, configuration.videoSampleFile == nil {
      throw ToolError.failure("video-smoke requires LMD_VIDEO_SAMPLE_FILE")
    }
    let runner = SmokeRunner(configuration: configuration)
    try await runner.run()
  }

  func tuiQA(target: String?) throws {
    _ = try runCaptured("tmux", ["-V"])
    var env = ProcessInfo.processInfo.environment
    env["LMD_BINARY_DIR"] = releaseBuildDirectory().path
    var args = ["qa"]
    if let target {
      args.append(target)
    }
    try runPassthrough(
      releaseBuildDirectory().appendingPathComponent("lmd").path, args, environment: env)
  }

  func logSmoke() throws {
    Output.debug("logSmoke")
    let captureFile = temporaryFileURL(prefix: "log-smoke", suffix: ".ndjson")
    let startDate = Date()
    try writeLine("[log-smoke] START \(logDateFormatter().string(from: startDate))")

    runBuiltLmdBestEffort(["--help"])
    runBuiltLmdBestEffort(["ls"])
    pollDelay(seconds: healthPollSeconds)

    let result = try runCaptured(
      "/usr/bin/log",
      [
        "show",
        "--predicate",
        "subsystem == 'io.goodkind.lmd'",
        "--start",
        logDateFormatter().string(from: startDate),
        "--style",
        "ndjson",
        "--info",
      ]
    )
    try result.output.write(to: captureFile, atomically: true, encoding: .utf8)
    try writeLine(
      "[log-smoke] capture size: \(result.output.split(separator: "\n").count) lines at \(captureFile.path)"
    )

    if result.output.contains("<private>") {
      throw ToolError.failure(
        "[log-smoke] FAILED: <private> redactions detected. Capture at \(captureFile.path)")
    }

    try removeIfExists(captureFile)
    try writeLine("[log-smoke] PASSED")
  }

  /// Run the built `lmd` binary for a logging exercise, logging rather than
  /// failing because log-smoke only cares about the unified-log output the run
  /// produces, not the command's own exit status.
  private func runBuiltLmdBestEffort(_ arguments: [String]) {
    do {
      try runPassthrough(releaseBuildDirectory().appendingPathComponent("lmd").path, arguments)
    } catch {
      Output.notice("log-smoke command failed arguments=\(arguments) error=\(error)")
    }
  }
}
