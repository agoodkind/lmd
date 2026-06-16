import Foundation
import Nimble
import SwiftLMCore
import SwiftLMHostProtocol
import SwiftLMRuntime
import XCTest

@testable import LMDServeSupport

private final class FakeModelServer: ModelServer, @unchecked Sendable {
  let modelID: String
  let sizeBytes: Int64
  var isRunning = true

  private let framesFor: @Sendable (BackendRequest) -> [BackendFrame]
  private let lock = NSLock()
  private var request: BackendRequest?

  var lastRequest: BackendRequest? {
    lock.lock()
    defer { lock.unlock() }
    return request
  }

  init(
    modelID: String,
    sizeBytes: Int64,
    framesFor: @escaping @Sendable (BackendRequest) -> [BackendFrame]
  ) {
    self.modelID = modelID
    self.sizeBytes = sizeBytes
    self.framesFor = framesFor
  }

  func spawn() {}
  func waitReady() {}

  func send(_ request: BackendRequest) -> AsyncThrowingStream<BackendFrame, Error> {
    lock.lock()
    self.request = request
    lock.unlock()
    let frames = framesFor(request)
    return AsyncThrowingStream { continuation in
      for frame in frames {
        continuation.yield(frame)
      }
      continuation.finish()
    }
  }

  func stats() -> BackendStats {
    BackendStats(rssBytes: 0, gpuActiveBytes: 0, gpuCacheBytes: 0)
  }

  func shutdown() {
    isRunning = false
  }
}

final class ModelServerRequestsTests: XCTestCase {
  func testBufferedChatResponseRoundTripsBodyAndRequestMetadata() async throws {
    let body = Data(#"{"id":"chatcmpl-test"}"#.utf8)
    let server = FakeModelServer(modelID: "model-a", sizeBytes: 42) { request in
      [
        .responseStarted(
          requestID: request.requestID,
          statusCode: 201,
          contentType: "application/json; charset=utf-8"
        ),
        .chunk(requestID: request.requestID, data: body),
        .done(requestID: request.requestID),
      ]
    }
    let prepared = preparedChatRequest(wantsStream: false)

    let result = try await completeChatWithModelServer(
      server: server,
      request: prepared,
      requestID: UUID(),
      headers: ["X-Test": "1"]
    )

    guard case .buffered(let statusCode, let contentType, let decodedBody) = result else {
      fail("expected buffered result")
      return
    }
    expect(statusCode) == 201
    expect(contentType) == "application/json"
    expect(decodedBody) == body
    expect(server.lastRequest?.kind) == .chat
    expect(server.lastRequest?.endpointPath) == "/v1/chat/completions"
    expect(server.lastRequest?.headers["X-Test"]) == "1"
  }

  func testStreamingChatResponsePropagatesRawBytes() async throws {
    let chunk = Data("data: hello\n\n".utf8)
    let server = FakeModelServer(modelID: "model-a", sizeBytes: 42) { request in
      [
        .responseStarted(
          requestID: request.requestID,
          statusCode: 200,
          contentType: "text/event-stream"
        ),
        .chunk(requestID: request.requestID, data: chunk),
        .done(requestID: request.requestID),
      ]
    }

    let result = try await completeChatWithModelServer(
      server: server,
      request: preparedChatRequest(wantsStream: true),
      requestID: UUID(),
      headers: [:]
    )

    guard
      case .streaming(let statusCode, let contentType, let events, let appendDoneFrame, _) = result
    else {
      fail("expected streaming result")
      return
    }
    expect(statusCode) == 200
    expect(contentType) == "text/event-stream"
    expect(appendDoneFrame) == false
    var received = Data()
    for try await event in events {
      if case .rawBytes(let data) = event {
        received.append(data)
      }
    }
    expect(received) == chunk
    expect(server.lastRequest?.stream ?? false) == true
  }

  func testEmbeddingRequestRoundTripsVectorsThroughVectorBlob() async throws {
    let expected: [[Float]] = [[1, 2, 3], [-1, 0.5, 4]]
    let server = FakeModelServer(modelID: "/m", sizeBytes: 42) { request in
      let (dims, payload) = VectorBlob.encode(expected)
      return [
        .vectors(requestID: request.requestID, dims: dims, payload: payload),
        .usage(requestID: request.requestID, promptTokens: 0, completionTokens: 0),
        .done(requestID: request.requestID),
      ]
    }

    let vectors = try await embedWithModelServer(
      server: server,
      inputs: ["a", "b"],
      requestID: UUID()
    )

    expect(vectors) == expected
    expect(server.lastRequest?.kind) == .embedding
    expect(server.lastRequest?.stream ?? true) == false
  }

  func testEmbeddingThrowsOnFailedFrame() async {
    let server = FakeModelServer(modelID: "/m", sizeBytes: 0) { request in
      [.failed(requestID: request.requestID, message: "boom")]
    }

    do {
      _ = try await embedWithModelServer(server: server, inputs: ["a"], requestID: UUID())
      fail("expected host failure")
    } catch let error as ModelServerEmbeddingError {
      expect(error) == .hostFailed(message: "boom")
    } catch {
      fail("expected ModelServerEmbeddingError, got \(error)")
    }
  }

  func testBufferedVideoResponseReconstructsThroughCodec() async throws {
    let body = Data(#"{"object":"chat.completion"}"#.utf8)
    let model = videoModel()
    let encoded = try await VideoFrameCodec.encode(
      result: .buffered(statusCode: 200, contentType: "application/json", body: body),
      requestID: UUID()
    )
    let server = FakeModelServer(modelID: model.id, sizeBytes: model.sizeBytes) { request in
      encoded.map { frame in rekey(frame, to: request.requestID) }
    }

    let result = try await completeVideoChatWithModelServer(
      server: server,
      request: routeRequest(model: model, wantsStream: false),
      requestID: UUID()
    )

    guard case .buffered(let statusCode, let contentType, let decodedBody) = result else {
      fail("expected buffered result")
      return
    }
    expect(statusCode) == 200
    expect(contentType) == "application/json"
    expect(decodedBody) == body
    expect(server.lastRequest?.kind) == .video
    expect(server.lastRequest?.stream ?? true) == false
  }

  func testStreamingVideoResponseForwardsBodyChunksAsRawBytes() async throws {
    let id = "chatcmpl-test"
    let model = videoModel()
    let events = AsyncThrowingStream<BackendStreamEvent, Error> { continuation in
      continuation.yield(.role(id: id, created: 1, model: model.id, role: "assistant"))
      continuation.yield(.content(id: id, created: 1, model: model.id, content: "hi"))
      continuation.yield(
        .finish(id: id, created: 1, model: model.id, finishReason: "stop", usage: nil))
      continuation.finish()
    }
    let encoded = try await VideoFrameCodec.encode(
      result: .streaming(
        statusCode: 200,
        contentType: "text/event-stream",
        events: events,
        appendDoneFrame: true,
        lifetimeToken: nil
      ),
      requestID: UUID()
    )
    // The reference body is every chunk after the header: the verbatim SSE bytes
    // the host serialized, including the terminal [DONE] line.
    var expected = Data()
    for frame in encoded.dropFirst() {
      if case .chunk(_, let bytes) = frame {
        expected.append(bytes)
      }
    }
    let server = FakeModelServer(modelID: model.id, sizeBytes: model.sizeBytes) { request in
      encoded.map { frame in rekey(frame, to: request.requestID) }
    }

    let result = try await completeVideoChatWithModelServer(
      server: server,
      request: routeRequest(model: model, wantsStream: true),
      requestID: UUID()
    )

    guard case let .streaming(statusCode, contentType, rebuilt, appendDone, _) = result
    else {
      fail("expected streaming result")
      return
    }
    expect(statusCode) == 200
    expect(contentType) == "text/event-stream"
    // The host already serialized [DONE]; the broker must not re-append one.
    expect(appendDone) == false
    var assembled = Data()
    for try await event in rebuilt {
      guard case .rawBytes(let bytes) = event else {
        fail("expected rawBytes events")
        return
      }
      assembled.append(bytes)
    }
    expect(assembled) == expected
    expect(server.lastRequest?.kind) == .video
    expect(server.lastRequest?.stream ?? false) == true
  }

  func testVideoMissingSamplingFPSThrowsTypedError() async {
    let model = ModelDescriptor(
      id: "/models/video",
      displayName: "Video",
      path: "/models/video",
      kind: .chat,
      capabilities: ModelCapabilities(video: true)
    )
    let server = FakeModelServer(modelID: model.id, sizeBytes: 0) { _ in [] }

    do {
      _ = try await completeVideoChatWithModelServer(
        server: server,
        request: routeRequest(model: model, wantsStream: false),
        requestID: UUID()
      )
      fail("expected missing videoSamplingFPS")
    } catch let error as VideoChatBackendError {
      expect(error) == .modelMissingVideoSamplingFPS(modelID: model.id)
    } catch {
      fail("expected VideoChatBackendError, got \(error)")
    }
  }
}

private func preparedChatRequest(wantsStream: Bool) -> PreparedChatRequest {
  let body = Data(#"{"model":"model-a","messages":[]}"#.utf8)
  let model = ModelDescriptor(
    id: "model-a",
    displayName: "Model A",
    path: "/models/a",
    sizeBytes: 42
  )
  return PreparedChatRequest(
    endpoint: .chatCompletions,
    bodyData: body,
    json: ["model": "model-a", "messages": []],
    model: model,
    wantsStream: wantsStream,
    mediaInspection: OpenAIVideoInspection(videos: [])
  )
}

private func videoModel() -> ModelDescriptor {
  ModelDescriptor(
    id: "/models/video",
    displayName: "Video",
    path: "/models/video",
    sizeBytes: 42,
    kind: .chat,
    capabilities: ModelCapabilities(video: true, videoSamplingFPS: 2)
  )
}

private func routeRequest(
  model: ModelDescriptor,
  wantsStream: Bool
) -> VideoChatRouteRequest {
  VideoChatRouteRequest(
    model: model,
    endpoint: .chatCompletions,
    bodyData: Data(#"{"model":"x","messages":[]}"#.utf8),
    wantsStream: wantsStream,
    videos: []
  )
}

private func rekey(_ frame: BackendFrame, to requestID: UUID) -> BackendFrame {
  switch frame {
  case .responseStarted(_, let statusCode, let contentType):
    return .responseStarted(
      requestID: requestID, statusCode: statusCode, contentType: contentType)
  case .chunk(_, let data):
    return .chunk(requestID: requestID, data: data)
  case .vectors(_, let dims, let payload):
    return .vectors(requestID: requestID, dims: dims, payload: payload)
  case .usage(_, let promptTokens, let completionTokens):
    return .usage(
      requestID: requestID,
      promptTokens: promptTokens,
      completionTokens: completionTokens
    )
  case .done:
    return .done(requestID: requestID)
  case .failed(_, let message):
    return .failed(requestID: requestID, message: message)
  case .hello, .ready, .stats, .metricsSnapshot:
    return frame
  }
}
