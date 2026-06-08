//
//  VideoChatRouting.swift
//  lmd-serve
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-05-09.
//  Copyright © 2026, all rights reserved.
//

import AppLogger
import Foundation
import Hummingbird
import MLXLMCommon
import SwiftLMBackend
import SwiftLMCore
import SwiftLMMetrics
import SwiftLMTrace

private let log = AppLogger.logger(category: "VideoChatRouting")

private let allowedVideoExtensions: Set<String> = [
  "avi",
  "m4v",
  "mkv",
  "mov",
  "mp4",
  "mpeg",
  "mpg",
  "webm",
]
public let maximumVideoFrameCount = 4_096

private struct ValidatedVideoURL {
  let originalURL: URL
  let fileURL: URL
}

public struct OpenAIVideoInput: Equatable, Sendable {
  public let url: URL
  public let fileURL: URL
  public let fps: Double?
  public let maxFrames: Int?
}

public struct OpenAIVideoInspection: Equatable, Sendable {
  public let videos: [OpenAIVideoInput]

  public init(videos: [OpenAIVideoInput]) {
    self.videos = videos
  }

  public var containsVideo: Bool {
    !videos.isEmpty
  }
}

public typealias ChatMediaInspection = OpenAIVideoInspection

public enum OpenAIVideoParseError: Error, Equatable, CustomStringConvertible {
  case videoURLObjectMissing
  case videoURLMissing
  case malformedURL(String)
  case unsupportedURLScheme(String?)
  case nonLocalFileHost(String)
  case relativeFileURL(String)
  case unsupportedExtension(String)
  case fileNotFound(String)
  case notRegularFile(String)
  case fileNotReadable(String)
  case invalidFPS
  case invalidMaxFrames

  public var description: String {
    switch self {
    case .videoURLObjectMissing:
      return "`video_url` content must include a video_url object"
    case .videoURLMissing:
      return "`video_url.url` must be a string"
    case .malformedURL(let value):
      return "`video_url.url` is not a valid URL: \(value)"
    case .unsupportedURLScheme(let scheme):
      return "`video_url.url` must use the file scheme, got \(scheme ?? "<none>")"
    case .nonLocalFileHost(let host):
      return "`video_url.url` must reference a local file, got host \(host)"
    case .relativeFileURL(let value):
      return "`video_url.url` must be an absolute file URL: \(value)"
    case .unsupportedExtension(let ext):
      return "`video_url.url` has unsupported video extension \(ext)"
    case .fileNotFound(let path):
      return "`video_url.url` file does not exist: \(path)"
    case .notRegularFile(let path):
      return "`video_url.url` must point to a regular file: \(path)"
    case .fileNotReadable(let path):
      return "`video_url.url` file is not readable: \(path)"
    case .invalidFPS:
      return "`video_url.fps` must be greater than 0"
    case .invalidMaxFrames:
      return "`video_url.max_frames` must be an integer from 1 through \(maximumVideoFrameCount)"
    }
  }
}

public struct VideoChatRouteRequest: Sendable {
  public let model: ModelDescriptor
  public let endpoint: OpenAIChatEndpoint
  public let bodyData: Data
  public let wantsStream: Bool
  public let videos: [OpenAIVideoInput]
  public let requestID: UUID?

  public init(
    model: ModelDescriptor,
    endpoint: OpenAIChatEndpoint,
    bodyData: Data,
    wantsStream: Bool,
    videos: [OpenAIVideoInput],
    requestID: UUID? = nil
  ) {
    self.model = model
    self.endpoint = endpoint
    self.bodyData = bodyData
    self.wantsStream = wantsStream
    self.videos = videos
    self.requestID = requestID
  }
}

public enum VideoChatBackendError: Error, Equatable, CustomStringConvertible {
  case notConfigured
  case modelMissingVideoSamplingFPS(modelID: String)

  public var description: String {
    switch self {
    case .notConfigured:
      return "video chat backend is not configured"
    case .modelMissingVideoSamplingFPS(let modelID):
      return
        "model \(modelID) advertises video capability but has no videoSamplingFPS; cannot sample frames"
    }
  }
}

public protocol VideoChatBackend: Sendable {
  func complete(_ request: VideoChatRouteRequest) async throws -> BackendChatResult
}

public struct NotConfiguredVideoChatBackend: VideoChatBackend {
  public init() {}

  public func complete(_ request: VideoChatRouteRequest) throws -> BackendChatResult {
    log.info(
      "video.backend_not_configured model=\(request.model.id, privacy: .public) video_count=\(request.videos.count, privacy: .public)"
    )
    throw VideoChatBackendError.notConfigured
  }
}

func effectiveSamplingFPS(modelFPS: Double, requestFPS: Double?) -> Double {
  requestFPS ?? modelFPS
}

public actor InProcessVLMVideoChatBackend: VideoChatBackend {
  private var backends: [String: MLXVLMVideoBackend] = [:]

  public init() {}

  public func complete(_ request: VideoChatRouteRequest) async throws -> BackendChatResult {
    let traceContext = videoTraceContext(request)
    let completionRequest = try makeMLXVLMVideoCompletionRequest(from: request.bodyData)
    guard let modelFPS = request.model.capabilities.videoSamplingFPS else {
      throw VideoChatBackendError.modelMissingVideoSamplingFPS(modelID: request.model.id)
    }
    // Request-side `fps` overrides the model's declared rate when present.
    // The model's declared rate is the default for callers that don't pass a
    // value. Frame sampling honours `max_frames` as an upper cap regardless of
    // the chosen FPS, so a runaway frame count is bounded by the request.
    let effectiveFPS = effectiveSamplingFPS(modelFPS: modelFPS, requestFPS: completionRequest.fps)
    let allVideoURLs =
      completionRequest.videoURLs
      + completionRequest.messages.flatMap(\.videoURLs)
    BackendTrace.debug(
      phase: TracePhase.Video.requestPreFrames.rawValue,
      context: traceContext,
      snapshot: .current(),
      extras: [
        "video_count": "\(allVideoURLs.count)",
        "effective_fps": "\(effectiveFPS)",
      ]
    )
    var preSampledVideos: [UserInput.Video] = []
    preSampledVideos.reserveCapacity(allVideoURLs.count)
    var totalFrames = 0
    for url in allVideoURLs {
      let frames = try await sampledVideoFrames(
        originalURL: url,
        targetFPS: effectiveFPS,
        maxFrames: completionRequest.maxFrames
      )
      totalFrames += frames.count
      preSampledVideos.append(.frames(frames))
    }
    BackendTrace.debug(
      phase: TracePhase.Video.requestPostFrames.rawValue,
      context: traceContext,
      snapshot: .current(),
      extras: [
        "sampled_frame_count": "\(totalFrames)",
        "video_count": "\(allVideoURLs.count)",
      ]
    )
    let preparedRequest = completionRequest.replacingVideos(
      preSampledVideos,
      sampledFrameCount: totalFrames,
      sampledFPS: effectiveFPS
    )
    let backend = try backend(for: request.model)
    BackendTrace.debug(
      phase: TracePhase.Video.requestPreGenerate.rawValue,
      context: traceContext,
      snapshot: .current(),
      extras: ["stream": "\(request.wantsStream)"]
    )
    if request.wantsStream {
      return try await streamCompletion(
        modelID: request.model.id,
        backend: backend,
        request: preparedRequest,
        traceContext: traceContext
      )
    }
    let completion = try await backend.complete(preparedRequest)
    if let usage = completion.usage {
      SwiftLMMetrics.addCounter(
        "lmd_tokens_total",
        usage.totalTokens,
        labels: [
          ("model_id", request.model.id),
          ("model_kind", "video"),
        ]
      )
    }
    BackendTrace.debug(
      phase: TracePhase.Video.requestPostGenerate.rawValue,
      context: traceContext,
      snapshot: .current(),
      extras: ["stream": "false"]
    )
    BackendTrace.debug(
      phase: TracePhase.Video.requestPreReturn.rawValue,
      context: traceContext,
      snapshot: .current(),
      extras: ["stream": "false"]
    )
    return .buffered(
      statusCode: 200,
      contentType: "application/json",
      body: try JSONEncoder().encode(completion)
    )
  }

  private func backend(for model: ModelDescriptor) throws -> MLXVLMVideoBackend {
    if let backend = backends[model.id] {
      return backend
    }
    let descriptor = try MLXVLMVideoModelDescriptor(descriptor: model)
    let backend = MLXVLMVideoBackend(model: descriptor)
    backends[model.id] = backend
    return backend
  }

  private func streamCompletion(
    modelID: String,
    backend: MLXVLMVideoBackend,
    request: MLXVLMVideoCompletionRequest,
    traceContext: TraceContext
  ) async throws -> BackendChatResult {
    let id = "chatcmpl-\(UUID().uuidString)"
    let created = Int(Date().timeIntervalSince1970)
    let generationEvents = try await backend.stream(request)
    let stream = AsyncThrowingStream<BackendStreamEvent, Error> { continuation in
      let task = Task {
        var completionInfo: MLXVLMVideoCompletionInfo?
        continuation.yield(.role(id: id, created: created, model: modelID, role: "assistant"))
        do {
          for try await event in generationEvents {
            switch event {
            case .chunk(let text):
              continuation.yield(.content(id: id, created: created, model: modelID, content: text))
            case .info(let info):
              completionInfo = info
            }
          }
          var extras = ["stream": "true"]
          if let completionInfo {
            extras["completion_tokens"] = "\(completionInfo.generationTokenCount)"
            extras["prompt_tokens"] = "\(completionInfo.promptTokenCount)"
          }
          BackendTrace.debug(
            phase: TracePhase.Video.requestPostGenerate.rawValue,
            context: traceContext,
            snapshot: .current(),
            extras: extras
          )
          let usage = completionInfo.map { info in
            BackendUsage(
              promptTokens: info.promptTokenCount,
              completionTokens: info.generationTokenCount,
              totalTokens: info.promptTokenCount + info.generationTokenCount
            )
          }
          if let usage {
            SwiftLMMetrics.addCounter(
              "lmd_tokens_total",
              usage.totalTokens,
              labels: [
                ("model_id", modelID),
                ("model_kind", "video"),
              ]
            )
          }
          continuation.yield(
            .finish(
              id: id,
              created: created,
              model: modelID,
              finishReason: completionInfo?.finishReason ?? "stop",
              usage: usage
            ))
          BackendTrace.debug(
            phase: TracePhase.Video.requestPreReturn.rawValue,
            context: traceContext,
            snapshot: .current(),
            extras: extras
          )
          continuation.finish()
        } catch {
          continuation.finish(throwing: error)
        }
      }
      continuation.onTermination = { @Sendable _ in
        task.cancel()
      }
    }
    return .streaming(
      statusCode: 200,
      contentType: "text/event-stream",
      events: stream,
      appendDoneFrame: true,
      lifetimeToken: nil
    )
  }
}

private func videoTraceContext(_ request: VideoChatRouteRequest) -> TraceContext {
  TraceContext(
    modelID: request.model.id,
    modelKind: .video,
    requestID: request.requestID
  )
}

public enum VideoChatRequestBuildError: Error, Equatable, CustomStringConvertible {
  case invalidJSON
  case missingMessages
  case invalidMessage
  case unsupportedRole(String)
  case unsupportedContent
  case noVideoContent
  case invalidMaxTokens
  case invalidTemperature

  public var description: String {
    switch self {
    case .invalidJSON:
      return "video chat request body must be valid JSON"
    case .missingMessages:
      return "video chat request must include a messages array"
    case .invalidMessage:
      return "video chat messages must be JSON objects"
    case .unsupportedRole(let role):
      return "video chat message role is not supported: \(role)"
    case .unsupportedContent:
      return "video chat message content must be a string or content-part array"
    case .noVideoContent:
      return "video chat request must include at least one video_url content part"
    case .invalidMaxTokens:
      return "video chat request max_tokens must be an integer greater than 0"
    case .invalidTemperature:
      return "video chat request temperature must be a number greater than or equal to 0"
    }
  }
}

public func makeMLXVLMVideoCompletionRequest(from bodyData: Data) throws
  -> MLXVLMVideoCompletionRequest
{
  guard let json = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any] else {
    throw VideoChatRequestBuildError.invalidJSON
  }
  guard let messages = json["messages"] as? [[String: Any]] else {
    throw VideoChatRequestBuildError.missingMessages
  }

  var videoMessages: [MLXVLMVideoMessage] = []
  videoMessages.reserveCapacity(messages.count)
  var videos: [OpenAIVideoInput] = []

  for message in messages {
    guard let roleName = message["role"] as? String else {
      throw VideoChatRequestBuildError.invalidMessage
    }
    let role = try videoMessageRole(roleName)
    let content = try videoMessageContent(message["content"])
    videos.append(contentsOf: content.videos)
    videoMessages.append(
      MLXVLMVideoMessage(
        role: role,
        content: content.text,
        videoURLs: content.videos.map(\.fileURL)
      ))
  }

  guard !videos.isEmpty else {
    throw VideoChatRequestBuildError.noVideoContent
  }

  return MLXVLMVideoCompletionRequest(
    messages: videoMessages,
    fps: videos.compactMap(\.fps).first,
    maxFrames: videos.compactMap(\.maxFrames).first,
    maxTokens: try parseMaxTokens(json["max_tokens"]) ?? 512,
    temperature: try parseTemperature(json["temperature"]) ?? 0.6
  )
}

public func inspectOpenAIVideoInputs(in json: [String: Any]) throws -> OpenAIVideoInspection {
  guard let messages = json["messages"] as? [[String: Any]] else {
    return OpenAIVideoInspection(videos: [])
  }

  var videos: [OpenAIVideoInput] = []
  for message in messages {
    guard let contentParts = message["content"] as? [[String: Any]] else {
      continue
    }
    for contentPart in contentParts {
      guard (contentPart["type"] as? String) == "video_url" else {
        continue
      }
      let video = try parseOpenAIVideoContentPart(contentPart)
      videos.append(video)
    }
  }

  return OpenAIVideoInspection(videos: videos)
}

private struct ParsedVideoMessageContent {
  let text: String
  let videos: [OpenAIVideoInput]
}

private func videoMessageRole(_ roleName: String) throws -> MLXVLMVideoMessage.Role {
  switch roleName {
  case "system", "developer":
    return .system
  case "user":
    return .user
  case "assistant":
    return .assistant
  default:
    throw VideoChatRequestBuildError.unsupportedRole(roleName)
  }
}

private func videoMessageContent(_ rawContent: Any?) throws -> ParsedVideoMessageContent {
  if let text = rawContent as? String {
    return ParsedVideoMessageContent(text: text, videos: [])
  }
  guard let contentParts = rawContent as? [[String: Any]] else {
    throw VideoChatRequestBuildError.unsupportedContent
  }

  var textParts: [String] = []
  var videos: [OpenAIVideoInput] = []
  for contentPart in contentParts {
    switch contentPart["type"] as? String {
    case "text":
      if let text = contentPart["text"] as? String {
        textParts.append(text)
      }
    case "video_url":
      videos.append(try parseOpenAIVideoContentPart(contentPart))
    default:
      continue
    }
  }

  return ParsedVideoMessageContent(
    text: textParts.joined(separator: "\n"),
    videos: videos
  )
}

private func parseOpenAIVideoContentPart(_ contentPart: [String: Any]) throws -> OpenAIVideoInput {
  guard let videoURL = contentPart["video_url"] as? [String: Any] else {
    throw OpenAIVideoParseError.videoURLObjectMissing
  }
  guard let urlString = videoURL["url"] as? String else {
    throw OpenAIVideoParseError.videoURLMissing
  }

  let fps = try parseFPS(videoURL["fps"])
  let maxFrames = try parseMaxFrames(videoURL["max_frames"])
  let validatedURL = try validateVideoFileURL(urlString)

  return OpenAIVideoInput(
    url: validatedURL.originalURL,
    fileURL: validatedURL.fileURL,
    fps: fps,
    maxFrames: maxFrames
  )
}

private func parseFPS(_ rawValue: Any?) throws -> Double? {
  guard let rawValue else {
    return nil
  }
  guard !isJSONBoolean(rawValue) else {
    throw OpenAIVideoParseError.invalidFPS
  }
  guard let value = doubleValue(rawValue) else {
    throw OpenAIVideoParseError.invalidFPS
  }
  guard value > 0 else {
    throw OpenAIVideoParseError.invalidFPS
  }
  return value
}

private func parseMaxFrames(_ rawValue: Any?) throws -> Int? {
  guard let rawValue else {
    return nil
  }
  guard !isJSONBoolean(rawValue) else {
    throw OpenAIVideoParseError.invalidMaxFrames
  }
  guard let frameCount = intValue(rawValue) else {
    throw OpenAIVideoParseError.invalidMaxFrames
  }
  guard frameCount > 0, frameCount <= maximumVideoFrameCount else {
    throw OpenAIVideoParseError.invalidMaxFrames
  }
  return frameCount
}

private func intValue(_ rawValue: Any?) -> Int? {
  guard let value = doubleValue(rawValue) else {
    return nil
  }
  guard value.rounded(.towardZero) == value else {
    return nil
  }
  return Int(value)
}

private func floatValue(_ rawValue: Any?) -> Float? {
  guard let value = doubleValue(rawValue) else {
    return nil
  }
  return Float(value)
}

private func doubleValue(_ rawValue: Any?) -> Double? {
  guard let rawValue, !isJSONBoolean(rawValue) else {
    return nil
  }
  if let number = rawValue as? NSNumber {
    return number.doubleValue
  }
  if let int = rawValue as? Int {
    return Double(int)
  }
  if let double = rawValue as? Double {
    return double
  }
  if let float = rawValue as? Float {
    return Double(float)
  }
  return nil
}

private func isJSONBoolean(_ rawValue: Any) -> Bool {
  guard let number = rawValue as? NSNumber else {
    return rawValue is Bool
  }
  return CFGetTypeID(number) == CFBooleanGetTypeID()
}

private func parseMaxTokens(_ rawValue: Any?) throws -> Int? {
  guard let rawValue else {
    return nil
  }
  guard let value = intValue(rawValue), value > 0 else {
    throw VideoChatRequestBuildError.invalidMaxTokens
  }
  return value
}

private func parseTemperature(_ rawValue: Any?) throws -> Float? {
  guard let rawValue else {
    return nil
  }
  guard let value = floatValue(rawValue), value >= 0, value.isFinite else {
    throw VideoChatRequestBuildError.invalidTemperature
  }
  return value
}

private func validateVideoFileURL(_ urlString: String) throws -> ValidatedVideoURL {
  guard let parsedURL = URL(string: urlString) else {
    throw OpenAIVideoParseError.malformedURL(urlString)
  }
  guard parsedURL.scheme == "file", parsedURL.isFileURL else {
    throw OpenAIVideoParseError.unsupportedURLScheme(parsedURL.scheme)
  }
  if let host = parsedURL.host, !host.isEmpty, host != "localhost" {
    throw OpenAIVideoParseError.nonLocalFileHost(host)
  }
  guard parsedURL.path.hasPrefix("/") else {
    throw OpenAIVideoParseError.relativeFileURL(urlString)
  }

  let fileURL = URL(fileURLWithPath: parsedURL.path).standardizedFileURL
  let path = fileURL.path
  let fileExtension = fileURL.pathExtension.lowercased()
  guard allowedVideoExtensions.contains(fileExtension) else {
    throw OpenAIVideoParseError.unsupportedExtension(fileExtension)
  }

  let fileManager = FileManager.default
  var isDirectory: ObjCBool = false
  guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory) else {
    throw OpenAIVideoParseError.fileNotFound(path)
  }
  guard !isDirectory.boolValue else {
    throw OpenAIVideoParseError.notRegularFile(path)
  }
  let resourceValues = try? fileURL.resourceValues(forKeys: [.isRegularFileKey])
  guard resourceValues?.isRegularFile == true else {
    throw OpenAIVideoParseError.notRegularFile(path)
  }
  guard fileManager.isReadableFile(atPath: path) else {
    throw OpenAIVideoParseError.fileNotReadable(path)
  }

  return ValidatedVideoURL(originalURL: parsedURL, fileURL: fileURL)
}
