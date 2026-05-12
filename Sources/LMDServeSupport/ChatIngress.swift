//
//  ChatIngress.swift
//  LMDServeSupport
//
//  Created by Alex Goodkind <alex@goodkind.io> on 2026-05-11.
//  Copyright © 2026
//

import Foundation
import Hummingbird
import SwiftLMCore

public enum OpenAIChatEndpoint: Sendable, Equatable {
  case chatCompletions
  case completions

  public var path: String {
    switch self {
    case .chatCompletions:
      return "/v1/chat/completions"
    case .completions:
      return "/v1/completions"
    }
  }
}

public struct ParsedChatIngress: @unchecked Sendable {
  public let endpoint: OpenAIChatEndpoint
  public let bodyData: Data
  public let json: [String: Any]
  public let modelID: String
  public let wantsStream: Bool
  public let mediaInspection: ChatMediaInspection

  public init(
    endpoint: OpenAIChatEndpoint,
    bodyData: Data,
    json: [String: Any],
    modelID: String,
    wantsStream: Bool,
    mediaInspection: ChatMediaInspection
  ) {
    self.endpoint = endpoint
    self.bodyData = bodyData
    self.json = json
    self.modelID = modelID
    self.wantsStream = wantsStream
    self.mediaInspection = mediaInspection
  }
}

public struct PreparedChatRequest: @unchecked Sendable {
  public let endpoint: OpenAIChatEndpoint
  public let bodyData: Data
  public let json: [String: Any]
  public let model: ModelDescriptor
  public let wantsStream: Bool
  public let mediaInspection: ChatMediaInspection

  public init(
    endpoint: OpenAIChatEndpoint,
    bodyData: Data,
    json: [String: Any],
    model: ModelDescriptor,
    wantsStream: Bool,
    mediaInspection: ChatMediaInspection
  ) {
    self.endpoint = endpoint
    self.bodyData = bodyData
    self.json = json
    self.model = model
    self.wantsStream = wantsStream
    self.mediaInspection = mediaInspection
  }
}

public enum ChatIngressError: Error, Equatable, CustomStringConvertible {
  case invalidJSON
  case missingModel
  case invalidVideo(OpenAIVideoParseError)

  public var description: String {
    switch self {
    case .invalidJSON, .missingModel:
      return "missing `model` field"
    case .invalidVideo(let error):
      return error.description
    }
  }
}

public enum ChatDispatchFailure: Error, Equatable, CustomStringConvertible {
  case embeddingModel
  case unsupportedVideoInput
  case unsupportedVideoEndpoint

  public var description: String {
    switch self {
    case .embeddingModel:
      return "model is an embedding model; use POST /v1/embeddings"
    case .unsupportedVideoInput:
      return "model does not support video input"
    case .unsupportedVideoEndpoint:
      return "video input is supported only on POST /v1/chat/completions"
    }
  }
}

public enum ChatDispatchTarget: Sendable, Equatable {
  case mlxVideo
  case swiftLMProxy
  case failure(ChatDispatchFailure)
}

public struct ChatDispatchRule: Sendable {
  public let name: String
  public let target: ChatDispatchTarget
  public let matches: @Sendable (PreparedChatRequest) -> Bool

  public init(
    name: String,
    target: ChatDispatchTarget,
    matches: @escaping @Sendable (PreparedChatRequest) -> Bool
  ) {
    self.name = name
    self.target = target
    self.matches = matches
  }
}

public enum ChatRoutingDecision: Sendable {
  case swiftLMProxy
  case videoBackend(VideoChatRouteRequest)
  case failure(ChatDispatchFailure)
}

public let defaultChatDispatchRules: [ChatDispatchRule] = [
  ChatDispatchRule(name: "embeddingModelsRejectChat", target: .failure(.embeddingModel)) { request in
    request.model.kind == .embedding
  },
  ChatDispatchRule(name: "videoRequiresChatCompletions", target: .failure(.unsupportedVideoEndpoint)) { request in
    request.mediaInspection.containsVideo && request.endpoint != .chatCompletions
  },
  ChatDispatchRule(name: "videoRequiresCapability", target: .failure(.unsupportedVideoInput)) { request in
    request.mediaInspection.containsVideo && !request.model.capabilities.video
  },
  ChatDispatchRule(name: "mlxVideo", target: .mlxVideo) { request in
    request.endpoint == .chatCompletions
      && request.mediaInspection.containsVideo
      && request.model.kind == .chat
      && request.model.capabilities.video
  },
  ChatDispatchRule(name: "swiftLMProxy", target: .swiftLMProxy) { request in
    !request.mediaInspection.containsVideo && request.model.kind == .chat
  },
]

public enum BackendChatResult: Sendable {
  case buffered(statusCode: Int, contentType: String, body: Data)
  case streaming(
    statusCode: Int,
    contentType: String,
    events: AsyncThrowingStream<BackendStreamEvent, Error>,
    appendDoneFrame: Bool,
    lifetimeToken: BackendLifetimeToken?
  )
}

public enum BackendStreamEvent: Sendable, Equatable {
  case rawBytes(Data)
  case role(id: String, created: Int, model: String, role: String)
  case content(id: String, created: Int, model: String, content: String)
  case finish(id: String, created: Int, model: String, finishReason: String, usage: BackendUsage?)
}

public struct BackendUsage: Codable, Equatable, Sendable {
  public let promptTokens: Int
  public let completionTokens: Int
  public let totalTokens: Int

  public init(promptTokens: Int, completionTokens: Int, totalTokens: Int) {
    self.promptTokens = promptTokens
    self.completionTokens = completionTokens
    self.totalTokens = totalTokens
  }

  enum CodingKeys: String, CodingKey {
    case promptTokens = "prompt_tokens"
    case completionTokens = "completion_tokens"
    case totalTokens = "total_tokens"
  }
}

public final class BackendLifetimeToken: @unchecked Sendable {
  private let lock = NSLock()
  private var didFinish = false
  private let onFinish: @Sendable () async -> Void

  public init(onFinish: @escaping @Sendable () async -> Void) {
    self.onFinish = onFinish
  }

  deinit {
    if markFinished() {
      let onFinish = self.onFinish
      Task {
        await onFinish()
      }
    }
  }

  public func finish() async {
    guard markFinished() else {
      return
    }
    await onFinish()
  }

  private func markFinished() -> Bool {
    lock.lock()
    defer {
      lock.unlock()
    }
    if didFinish {
      return false
    }
    didFinish = true
    return true
  }
}

public struct BackendStreamingBodySequence: AsyncSequence, Sendable {
  public typealias Element = ByteBuffer

  private let events: AsyncThrowingStream<BackendStreamEvent, Error>
  private let appendDoneFrame: Bool
  private let lifetimeToken: BackendLifetimeToken?

  public init(
    events: AsyncThrowingStream<BackendStreamEvent, Error>,
    appendDoneFrame: Bool,
    lifetimeToken: BackendLifetimeToken?
  ) {
    self.events = events
    self.appendDoneFrame = appendDoneFrame
    self.lifetimeToken = lifetimeToken
  }

  public func makeAsyncIterator() -> Iterator {
    Iterator(
      upstream: events.makeAsyncIterator(),
      appendDoneFrame: appendDoneFrame,
      lifetimeToken: lifetimeToken
    )
  }

  public struct Iterator: AsyncIteratorProtocol {
    private var upstream: AsyncThrowingStream<BackendStreamEvent, Error>.Iterator
    private let appendDoneFrame: Bool
    private let lifetimeToken: BackendLifetimeToken?
    private var sentDoneFrame = false
    private var didFinish = false

    fileprivate init(
      upstream: AsyncThrowingStream<BackendStreamEvent, Error>.Iterator,
      appendDoneFrame: Bool,
      lifetimeToken: BackendLifetimeToken?
    ) {
      self.upstream = upstream
      self.appendDoneFrame = appendDoneFrame
      self.lifetimeToken = lifetimeToken
    }

    public mutating func next() async throws -> ByteBuffer? {
      if didFinish {
        return nil
      }
      do {
        guard let event = try await upstream.next() else {
          if appendDoneFrame && !sentDoneFrame {
            sentDoneFrame = true
            return ByteBuffer(data: backendDoneFrame())
          }
          didFinish = true
          await lifetimeToken?.finish()
          return nil
        }
        return ByteBuffer(data: try encodeBackendStreamEvent(event))
      } catch {
        didFinish = true
        await lifetimeToken?.finish()
        throw error
      }
    }
  }
}

public func parseChatIngress(
  endpoint: OpenAIChatEndpoint,
  bodyData: Data
) throws -> ParsedChatIngress {
  guard let json = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any] else {
    throw ChatIngressError.invalidJSON
  }
  guard let modelID = json["model"] as? String else {
    throw ChatIngressError.missingModel
  }
  let mediaInspection: ChatMediaInspection
  do {
    mediaInspection = try inspectOpenAIVideoInputs(in: json)
  } catch let error as OpenAIVideoParseError {
    throw ChatIngressError.invalidVideo(error)
  }
  return ParsedChatIngress(
    endpoint: endpoint,
    bodyData: bodyData,
    json: json,
    modelID: modelID,
    wantsStream: (json["stream"] as? Bool) ?? false,
    mediaInspection: mediaInspection
  )
}

public func prepareChatRequest(
  ingress: ParsedChatIngress,
  bodyData: Data,
  json: [String: Any],
  model: ModelDescriptor
) -> PreparedChatRequest {
  PreparedChatRequest(
    endpoint: ingress.endpoint,
    bodyData: bodyData,
    json: json,
    model: model,
    wantsStream: ingress.wantsStream,
    mediaInspection: ingress.mediaInspection
  )
}

public func dispatchChatRequest(
  _ request: PreparedChatRequest,
  rules: [ChatDispatchRule] = defaultChatDispatchRules
) -> ChatRoutingDecision {
  for rule in rules where rule.matches(request) {
    switch rule.target {
    case .mlxVideo:
      return .videoBackend(
        VideoChatRouteRequest(
          model: request.model,
          endpoint: request.endpoint,
          bodyData: request.bodyData,
          wantsStream: request.wantsStream,
          videos: request.mediaInspection.videos
        ))
    case .swiftLMProxy:
      return .swiftLMProxy
    case .failure(let failure):
      return .failure(failure)
    }
  }
  return .failure(.unsupportedVideoInput)
}

public func chatRoutingDecision(
  path: String,
  bodyData: Data,
  model: ModelDescriptor,
  wantsStream: Bool,
  videoInspection: ChatMediaInspection
) -> ChatRoutingDecision {
  let endpoint: OpenAIChatEndpoint
  if path == OpenAIChatEndpoint.completions.path {
    endpoint = .completions
  } else {
    endpoint = .chatCompletions
  }
  let prepared = PreparedChatRequest(
    endpoint: endpoint,
    bodyData: bodyData,
    json: [:],
    model: model,
    wantsStream: wantsStream,
    mediaInspection: videoInspection
  )
  return dispatchChatRequest(prepared)
}

public func backendErrorResult(
  statusCode: Int,
  message: String,
  type: String,
  code: String? = nil
) -> BackendChatResult {
  let envelope = ChatErrorEnvelope(
    error: ChatErrorEnvelope.Body(message: message, type: type, code: code)
  )
  let body = (try? JSONEncoder().encode(envelope)) ?? Data()
  return .buffered(statusCode: statusCode, contentType: "application/json", body: body)
}

public func renderBackendChatResult(_ result: BackendChatResult) -> Response {
  switch result {
  case .buffered(let statusCode, let contentType, let body):
    return Response(
      status: HTTPResponse.Status(code: numericCast(statusCode)),
      headers: [.contentType: contentType],
      body: .init(byteBuffer: ByteBuffer(data: body))
    )
  case .streaming(let statusCode, let contentType, let events, let appendDoneFrame, let lifetimeToken):
    let body = ResponseBody(
      asyncSequence: BackendStreamingBodySequence(
        events: events,
        appendDoneFrame: appendDoneFrame,
        lifetimeToken: lifetimeToken
      ))
    return Response(
      status: HTTPResponse.Status(code: numericCast(statusCode)),
      headers: [
        .contentType: contentType,
        .cacheControl: "no-cache",
      ],
      body: body
    )
  }
}

public func encodeBackendStreamEvent(_ event: BackendStreamEvent) throws -> Data {
  switch event {
  case .rawBytes(let data):
    return data
  case .role(let id, let created, let model, let role):
    let chunk = ChatCompletionChunk(
      id: id,
      created: created,
      model: model,
      choices: [
        ChatCompletionChunk.Choice(
          index: 0,
          delta: ChatCompletionChunk.Delta(role: role, content: nil),
          finishReason: nil
        )
      ],
      usage: nil
    )
    return try encodeSSEData(chunk)
  case .content(let id, let created, let model, let content):
    let chunk = ChatCompletionChunk(
      id: id,
      created: created,
      model: model,
      choices: [
        ChatCompletionChunk.Choice(
          index: 0,
          delta: ChatCompletionChunk.Delta(role: nil, content: content),
          finishReason: nil
        )
      ],
      usage: nil
    )
    return try encodeSSEData(chunk)
  case .finish(let id, let created, let model, let finishReason, let usage):
    let chunk = ChatCompletionChunk(
      id: id,
      created: created,
      model: model,
      choices: [
        ChatCompletionChunk.Choice(
          index: 0,
          delta: ChatCompletionChunk.Delta(role: nil, content: nil),
          finishReason: finishReason
        )
      ],
      usage: usage
    )
    return try encodeSSEData(chunk)
  }
}

public func backendDoneFrame() -> Data {
  Data("data: [DONE]\n\n".utf8)
}

private struct ChatErrorEnvelope: Codable {
  let error: Body

  struct Body: Codable {
    let message: String
    let type: String
    let code: String?
  }
}

private struct ChatCompletionChunk: Encodable {
  let id: String
  let object = "chat.completion.chunk"
  let created: Int
  let model: String
  let choices: [Choice]
  let usage: BackendUsage?

  struct Choice: Encodable {
    let index: Int
    let delta: Delta
    let finishReason: String?

    enum CodingKeys: String, CodingKey {
      case index
      case delta
      case finishReason = "finish_reason"
    }
  }

  struct Delta: Encodable {
    let role: String?
    let content: String?
  }
}

private func encodeSSEData<T: Encodable>(_ value: T) throws -> Data {
  let payload = try JSONEncoder().encode(value)
  var data = Data("data: ".utf8)
  data.append(payload)
  data.append(Data("\n\n".utf8))
  return data
}
