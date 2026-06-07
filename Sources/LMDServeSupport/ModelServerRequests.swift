//
//  ModelServerRequests.swift
//  LMDServeSupport
//
//  Routes broker requests through the uniform `ModelServer` abstraction while
//  preserving the OpenAI response rendering previously owned by the transitional
//  XPC adapter types.
//

import Foundation
import SwiftLMHostProtocol
import SwiftLMRuntime

public enum ModelServerChatError: Error, Equatable {
  case hostFailed(message: String)
  case missingResponseStarted
}

public enum ModelServerEmbeddingError: Error, Equatable {
  case hostFailed(message: String)
  case noVectorsReturned
}

public enum ModelServerVideoChatError: Error, Equatable {
  case hostFailed(message: String)
}

private struct ModelServerChatResponseHeader: Sendable {
  let statusCode: Int
  let contentType: String
}

private actor ModelServerChatHeaderBox {
  private var result: Result<ModelServerChatResponseHeader, Error>?
  private var waiters: [CheckedContinuation<ModelServerChatResponseHeader, Error>] = []

  func wait() async throws -> ModelServerChatResponseHeader {
    if let result {
      return try result.get()
    }
    return try await withCheckedThrowingContinuation { continuation in
      waiters.append(continuation)
    }
  }

  func succeed(_ header: ModelServerChatResponseHeader) {
    complete(.success(header))
  }

  func fail(_ error: Error) {
    complete(.failure(error))
  }

  private func complete(_ nextResult: Result<ModelServerChatResponseHeader, Error>) {
    guard result == nil else {
      return
    }
    result = nextResult
    let continuations = waiters
    waiters.removeAll()
    for continuation in continuations {
      continuation.resume(with: nextResult)
    }
  }
}

public func completeChatWithModelServer(
  server: ModelServer,
  request: PreparedChatRequest,
  requestID: UUID,
  headers: [String: String]
) async throws -> BackendChatResult {
  let backendRequest = BackendRequest(
    requestID: requestID,
    kind: .chat,
    openAIBody: request.bodyData,
    stream: request.wantsStream,
    endpointPath: request.endpoint.path,
    headers: headers
  )
  if request.wantsStream {
    return try await streamingChatResult(frames: server.send(backendRequest))
  }
  return try await bufferedChatResult(frames: server.send(backendRequest))
}

public func embedWithModelServer(
  server: ModelServer,
  inputs: [String],
  requestID: UUID
) async throws -> [[Float]] {
  let body = try JSONSerialization.data(withJSONObject: ["input": inputs])
  let request = BackendRequest(
    requestID: requestID,
    kind: .embedding,
    openAIBody: body,
    stream: false
  )
  var decoded: [[Float]]?
  for try await frame in server.send(request) {
    switch frame {
    case .vectors(_, let dims, let payload):
      decoded = try VectorBlob.decode(dims: dims, payload: payload)
    case .failed(_, let message):
      throw ModelServerEmbeddingError.hostFailed(message: message)
    case .done:
      break
    default:
      break
    }
  }
  guard let decoded else {
    throw ModelServerEmbeddingError.noVectorsReturned
  }
  return decoded
}

public func completeVideoChatWithModelServer(
  server: ModelServer,
  request: VideoChatRouteRequest,
  requestID: UUID
) async throws -> BackendChatResult {
  guard request.model.capabilities.videoSamplingFPS != nil else {
    throw VideoChatBackendError.modelMissingVideoSamplingFPS(modelID: request.model.id)
  }
  let backendRequest = BackendRequest(
    requestID: requestID,
    kind: .video,
    openAIBody: request.bodyData,
    stream: request.wantsStream
  )
  return try await VideoFrameCodec.decode(frames: server.send(backendRequest))
}

private func bufferedChatResult(
  frames: AsyncThrowingStream<BackendFrame, Error>
) async throws -> BackendChatResult {
  var header: ModelServerChatResponseHeader?
  var body = Data()
  for try await frame in frames {
    switch frame {
    case .responseStarted(_, let statusCode, let contentType):
      header = ModelServerChatResponseHeader(statusCode: statusCode, contentType: contentType)
    case .chunk(_, let data):
      body.append(data)
    case .failed(_, let message):
      throw ModelServerChatError.hostFailed(message: message)
    case .done:
      guard let header else {
        throw ModelServerChatError.missingResponseStarted
      }
      return .buffered(
        statusCode: header.statusCode,
        contentType: "application/json",
        body: body
      )
    default:
      continue
    }
  }
  throw ModelServerChatError.missingResponseStarted
}

private func streamingChatResult(
  frames: AsyncThrowingStream<BackendFrame, Error>
) async throws -> BackendChatResult {
  let headerBox = ModelServerChatHeaderBox()
  let events = AsyncThrowingStream<BackendStreamEvent, Error> { continuation in
    let task = Task {
      var sawHeader = false
      do {
        for try await frame in frames {
          switch frame {
          case .responseStarted(_, let statusCode, let contentType):
            sawHeader = true
            await headerBox.succeed(
              ModelServerChatResponseHeader(statusCode: statusCode, contentType: contentType))
          case .chunk(_, let data):
            continuation.yield(.rawBytes(data))
          case .failed(_, let message):
            let error = ModelServerChatError.hostFailed(message: message)
            if !sawHeader {
              await headerBox.fail(error)
            }
            continuation.finish(throwing: error)
            return
          case .done:
            if !sawHeader {
              await headerBox.fail(ModelServerChatError.missingResponseStarted)
              continuation.finish(throwing: ModelServerChatError.missingResponseStarted)
              return
            }
            continuation.finish()
            return
          default:
            continue
          }
        }
        if !sawHeader {
          await headerBox.fail(ModelServerChatError.missingResponseStarted)
          continuation.finish(throwing: ModelServerChatError.missingResponseStarted)
          return
        }
        continuation.finish()
      } catch {
        if !sawHeader {
          await headerBox.fail(error)
        }
        continuation.finish(throwing: error)
      }
    }
    continuation.onTermination = { @Sendable _ in
      task.cancel()
    }
  }
  let header = try await headerBox.wait()
  return .streaming(
    statusCode: header.statusCode,
    contentType: header.contentType,
    events: events,
    appendDoneFrame: false,
    lifetimeToken: nil
  )
}
