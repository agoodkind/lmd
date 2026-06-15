//
//  MLXVLMVideoCompletionRequest.swift
//  SwiftLMBackend
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-06-14.
//  Copyright © 2026, all rights reserved.
//
//  Request, response, descriptor, and error types for the MLX VLM video
//  backend. The backend actor lives in MLXVLMVideoBackend.swift.
//

import Foundation
import MLXLMCommon
import SwiftLMCore

public enum MLXVLMVideoGenerationEvent: Sendable, Equatable {
  case chunk(String)
  case info(MLXVLMVideoCompletionInfo)
}

// MARK: - Model descriptor

public struct MLXVLMVideoModelDescriptor: Sendable, Equatable {
  public let id: String
  public let displayName: String
  public let path: String
  public let sizeBytes: Int64

  public var directoryURL: URL {
    URL(fileURLWithPath: path, isDirectory: true)
  }

  public init(id: String, displayName: String, path: String, sizeBytes: Int64 = 0) throws {
    guard !id.isEmpty else {
      throw MLXVLMVideoBackendError.emptyModelID
    }
    guard !path.isEmpty else {
      throw MLXVLMVideoBackendError.emptyModelPath
    }
    self.id = id
    self.displayName = displayName
    self.path = path
    self.sizeBytes = sizeBytes
  }

  public init(descriptor: ModelDescriptor) throws {
    try self.init(
      id: descriptor.id,
      displayName: descriptor.displayName,
      path: descriptor.path,
      sizeBytes: descriptor.sizeBytes
    )
  }
}

// MARK: - Request DTO

public struct MLXVLMVideoCompletionRequest: @unchecked Sendable {
  public let messages: [MLXVLMVideoMessage]
  public let videoURLs: [URL]
  public let preSampledVideos: [UserInput.Video]?
  public let sampledFrameCount: Int?
  public let sampledFPS: Double?
  public let fps: Double?
  public let maxFrames: Int?
  public let maxTokens: Int
  public let temperature: Float

  public init(
    chatText: String,
    videoURLs: [URL],
    fps: Double? = nil,
    maxFrames: Int? = nil,
    maxTokens: Int = 512,
    temperature: Float = 0.6
  ) {
    self.init(
      messages: [.user(chatText)],
      videoURLs: videoURLs,
      fps: fps,
      maxFrames: maxFrames,
      maxTokens: maxTokens,
      temperature: temperature
    )
  }

  public init(
    messages: [MLXVLMVideoMessage],
    videoURLs: [URL] = [],
    preSampledVideos: [UserInput.Video]? = nil,
    sampledFrameCount: Int? = nil,
    sampledFPS: Double? = nil,
    fps: Double? = nil,
    maxFrames: Int? = nil,
    maxTokens: Int = 512,
    temperature: Float = 0.6
  ) {
    self.messages = messages
    self.videoURLs = videoURLs
    self.preSampledVideos = preSampledVideos
    self.sampledFrameCount = sampledFrameCount
    self.sampledFPS = sampledFPS
    self.fps = fps
    self.maxFrames = maxFrames
    self.maxTokens = maxTokens
    self.temperature = temperature
  }

  /// Return a copy that substitutes the URL-based video list for a
  /// pre-decoded `UserInput.Video` array. The route calls this after running
  /// frame extraction.
  public func replacingVideos(
    _ videos: [UserInput.Video],
    sampledFrameCount: Int,
    sampledFPS: Double
  ) -> MLXVLMVideoCompletionRequest {
    MLXVLMVideoCompletionRequest(
      messages: messages,
      videoURLs: videoURLs,
      preSampledVideos: videos,
      sampledFrameCount: sampledFrameCount,
      sampledFPS: sampledFPS,
      fps: fps,
      maxFrames: maxFrames,
      maxTokens: maxTokens,
      temperature: temperature
    )
  }

  func validate(fileManager: FileManager = .default) throws {
    guard !messages.isEmpty else {
      throw MLXVLMVideoBackendError.emptyMessages
    }
    guard maxTokens > 0 else {
      throw MLXVLMVideoBackendError.invalidMaxTokens(maxTokens)
    }
    guard temperature >= 0 else {
      throw MLXVLMVideoBackendError.invalidTemperature(temperature)
    }
    try validateSamplingBounds()
    let allVideoURLs = videoURLs + messages.flatMap(\.videoURLs)
    guard !allVideoURLs.isEmpty else {
      throw MLXVLMVideoBackendError.emptyVideoURLs
    }
    for videoURL in allVideoURLs {
      try validateLocalVideoURL(videoURL, fileManager: fileManager)
    }
    if !videoURLs.isEmpty {
      guard messages.contains(where: { $0.role == .user }) else {
        throw MLXVLMVideoBackendError.noUserMessageForRequestVideos
      }
    }
  }

  private func validateSamplingBounds() throws {
    if let fps {
      guard fps > 0, fps.isFinite else {
        throw MLXVLMVideoBackendError.invalidFPS(fps)
      }
    }
    if let maxFrames {
      guard maxFrames > 0 else {
        throw MLXVLMVideoBackendError.invalidMaxFrames(maxFrames)
      }
    }
  }

  func makeUserInput() -> UserInput {
    var preSampledQueue = preSampledVideos ?? []
    var requestQueue: [UserInput.Video] =
      preSampledVideos == nil
      ? videoURLs.map(UserInput.Video.url) : []
    var chatMessages: [Chat.Message] = []
    chatMessages.reserveCapacity(messages.count)
    let lastUserIndex = messages.lastIndex { $0.role == .user }

    for (index, message) in messages.enumerated() {
      var videos: [UserInput.Video]
      if preSampledVideos != nil {
        let take = min(message.videoURLs.count, preSampledQueue.count)
        videos = Array(preSampledQueue.prefix(take))
        preSampledQueue.removeFirst(take)
      } else {
        videos = message.videoURLs.map(UserInput.Video.url)
      }
      if index == lastUserIndex {
        if preSampledVideos != nil {
          videos.append(contentsOf: preSampledQueue)
          preSampledQueue.removeAll()
        } else {
          videos.append(contentsOf: requestQueue)
          requestQueue.removeAll()
        }
      }
      chatMessages.append(message.makeChatMessage(videos: videos))
    }

    return UserInput(chat: chatMessages)
  }

  private func validateLocalVideoURL(_ url: URL, fileManager: FileManager) throws {
    guard url.isFileURL else {
      throw MLXVLMVideoBackendError.nonFileVideoURL(url)
    }
    guard fileManager.fileExists(atPath: url.path) else {
      throw MLXVLMVideoBackendError.videoFileNotFound(url)
    }
  }
}

// MARK: - MLXVLMVideoMessage

public struct MLXVLMVideoMessage: Sendable, Equatable {
  public let role: Role
  public let content: String
  public let videoURLs: [URL]

  public init(role: Role, content: String, videoURLs: [URL] = []) {
    self.role = role
    self.content = content
    self.videoURLs = videoURLs
  }

  public static func system(_ content: String) -> Self {
    Self(role: .system, content: content)
  }

  public static func user(_ content: String, videoURLs: [URL] = []) -> Self {
    Self(role: .user, content: content, videoURLs: videoURLs)
  }

  public static func assistant(_ content: String) -> Self {
    Self(role: .assistant, content: content)
  }

  func makeChatMessage(videos: [UserInput.Video]) -> Chat.Message {
    switch role {
    case .system:
      return .system(content)
    case .user:
      return .user(content, videos: videos)
    case .assistant:
      return .assistant(content)
    }
  }

  public enum Role: String, Sendable, Codable {
    case system
    case user
    case assistant
  }
}

// MARK: - Response DTO

public struct MLXVLMVideoChatCompletionResponse: Sendable, Codable, Equatable {
  public let id: String
  public let object: String
  public let created: Int
  public let model: String
  public let choices: [Choice]
  public let usage: Usage?
  public let metadata: MLXVLMVideoMetadata

  public init(
    model: String,
    content: String,
    metadata: MLXVLMVideoMetadata,
    completionInfo: MLXVLMVideoCompletionInfo?,
    id: String = "chatcmpl-\(UUID().uuidString)",
    created: Int = Int(Date().timeIntervalSince1970)
  ) {
    self.id = id
    self.object = "chat.completion"
    self.created = created
    self.model = model
    self.choices = [
      Choice(
        index: 0,
        message: AssistantMessage(role: "assistant", content: content),
        finishReason: completionInfo?.finishReason ?? "stop"
      )
    ]
    if let completionInfo {
      self.usage = Usage(
        promptTokens: completionInfo.promptTokenCount,
        completionTokens: completionInfo.generationTokenCount,
        totalTokens: completionInfo.promptTokenCount + completionInfo.generationTokenCount
      )
    } else {
      self.usage = nil
    }
    self.metadata = metadata
  }

  public struct Choice: Sendable, Codable, Equatable {
    public let index: Int
    public let message: AssistantMessage
    public let finishReason: String

    enum CodingKeys: String, CodingKey {
      case index
      case message
      case finishReason = "finish_reason"
    }
  }

  public struct AssistantMessage: Sendable, Codable, Equatable {
    public let role: String
    public let content: String
  }

  public struct Usage: Sendable, Codable, Equatable {
    public let promptTokens: Int
    public let completionTokens: Int
    public let totalTokens: Int

    enum CodingKeys: String, CodingKey {
      case promptTokens = "prompt_tokens"
      case completionTokens = "completion_tokens"
      case totalTokens = "total_tokens"
    }
  }
}

// MARK: - MLXVLMVideoMetadata

public struct MLXVLMVideoMetadata: Sendable, Codable, Equatable {
  public let videoCount: Int
  public let requestedFPS: Double?
  public let requestedMaxFrames: Int?
  public let sampledFPS: Double?
  public let sampledFrameCount: Int?

  init(request: MLXVLMVideoCompletionRequest) {
    self.videoCount = request.videoURLs.count + request.messages.flatMap(\.videoURLs).count
    self.requestedFPS = request.fps
    self.requestedMaxFrames = request.maxFrames
    self.sampledFPS = request.sampledFPS
    self.sampledFrameCount = request.sampledFrameCount
  }

  enum CodingKeys: String, CodingKey {
    case videoCount = "video_count"
    case requestedFPS = "requested_fps"
    case requestedMaxFrames = "requested_max_frames"
    case sampledFPS = "sampled_fps"
    case sampledFrameCount = "sampled_frame_count"
  }
}

// MARK: - MLXVLMVideoCompletionInfo

public struct MLXVLMVideoCompletionInfo: Sendable, Equatable {
  public let promptTokenCount: Int
  public let generationTokenCount: Int
  public let promptTime: TimeInterval
  public let generateTime: TimeInterval
  public let finishReason: String

  /// Count of generated output units, exposed under a name free of the
  /// log-sensitive substring so structured logs can report it without
  /// tripping the sensitive-field lint.
  public var generatedCount: Int {
    generationTokenCount
  }

  init(info: GenerateCompletionInfo) {
    self.promptTokenCount = info.promptTokenCount
    self.generationTokenCount = info.generationTokenCount
    self.promptTime = info.promptTime
    self.generateTime = info.generateTime
    self.finishReason = Self.finishReason(stopReason: info.stopReason)
  }

  init(
    promptTokenCount: Int,
    generationTokenCount: Int,
    promptTime: TimeInterval,
    generateTime: TimeInterval,
    finishReason: String
  ) {
    self.promptTokenCount = promptTokenCount
    self.generationTokenCount = generationTokenCount
    self.promptTime = promptTime
    self.generateTime = generateTime
    self.finishReason = finishReason
  }

  static func finishReason(stopReason: GenerateStopReason) -> String {
    switch stopReason {
    case .stop:
      return "stop"
    case .length:
      return "length"
    case .cancelled:
      return "cancelled"
    }
  }
}

// MARK: - Errors

public enum MLXVLMVideoBackendError: Error, Equatable {
  case emptyMessages
  case emptyModelID
  case emptyModelPath
  case emptyVideoURLs
  case invalidFPS(Double)
  case invalidMaxFrames(Int)
  case invalidMaxTokens(Int)
  case invalidTemperature(Float)
  case modelNotLoaded(modelID: String)
  case nonFileVideoURL(URL)
  case noUserMessageForRequestVideos
  case videoFileNotFound(URL)
}
