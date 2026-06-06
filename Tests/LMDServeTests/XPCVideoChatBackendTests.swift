import Foundation
import SwiftLMCore
import SwiftLMHostProtocol
import SwiftLMRuntime
import XCTest

@testable import LMDServeSupport

/// A ModelServer that never spawns a process. It replays a scripted frame
/// sequence for each request so the video adapter's stream consumption and
/// result reconstruction can be exercised in isolation.
private final class FakeModelServer: ModelServer, @unchecked Sendable {
  let modelID: String
  let sizeBytes: Int64
  private let framesFor: @Sendable (BackendRequest) -> [BackendFrame]
  private(set) var lastRequest: BackendRequest?
  private(set) var didShutdown = false

  init(
    modelID: String,
    sizeBytes: Int64,
    framesFor: @escaping @Sendable (BackendRequest) -> [BackendFrame]
  ) {
    self.modelID = modelID
    self.sizeBytes = sizeBytes
    self.framesFor = framesFor
  }

  func spawn() async throws {}
  func waitReady() async throws {}

  func send(_ request: BackendRequest) -> AsyncThrowingStream<BackendFrame, Error> {
    lastRequest = request
    let frames = framesFor(request)
    return AsyncThrowingStream { continuation in
      for frame in frames {
        continuation.yield(frame)
      }
      continuation.finish()
    }
  }

  func stats() async -> BackendStats {
    BackendStats(rssBytes: 0, gpuActiveBytes: 0, gpuCacheBytes: 0)
  }

  func shutdown() { didShutdown = true }
}

final class XPCVideoChatBackendTests: XCTestCase {
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

  func testBufferedResponseReconstructsThroughTheCodec() async throws {
    let body = Data(#"{"object":"chat.completion"}"#.utf8)
    let model = videoModel()
    // The fake stands in for the host: it replays frames the host would have
    // serialized with the real codec, so the adapter exercises the real decode.
    let encoded = try await VideoFrameCodec.encode(
      result: .buffered(statusCode: 200, contentType: "application/json", body: body),
      requestID: UUID()
    )
    let server = FakeModelServer(modelID: model.id, sizeBytes: model.sizeBytes) { request in
      encoded.map { frame in rekey(frame, to: request.requestID) }
    }
    let backend = XPCVideoChatBackend { _ in server }

    let result = try await backend.complete(routeRequest(model: model, wantsStream: false))

    guard case .buffered(let statusCode, let contentType, let decodedBody) = result else {
      return XCTFail("expected buffered result")
    }
    XCTAssertEqual(statusCode, 200)
    XCTAssertEqual(contentType, "application/json")
    XCTAssertEqual(decodedBody, body)
    XCTAssertEqual(server.lastRequest?.kind, .video)
    XCTAssertFalse(server.lastRequest?.stream ?? true)
  }

  func testStreamingResponsePropagatesStreamFlagAndRawBytes() async throws {
    let id = "chatcmpl-test"
    let model = videoModel()
    let events = AsyncThrowingStream<BackendStreamEvent, Error> { continuation in
      continuation.yield(.content(id: id, created: 1, model: model.id, content: "frame"))
      continuation.finish()
    }
    let streamingResult = BackendChatResult.streaming(
      statusCode: 200,
      contentType: "text/event-stream",
      events: events,
      appendDoneFrame: true,
      lifetimeToken: nil
    )
    let encoded = try await VideoFrameCodec.encode(
      result: streamingResult, requestID: UUID())
    let server = FakeModelServer(modelID: model.id, sizeBytes: model.sizeBytes) { request in
      // Re-key the pre-encoded frames onto the live request id.
      encoded.map { frame in rekey(frame, to: request.requestID) }
    }
    let backend = XPCVideoChatBackend { _ in server }

    let result = try await backend.complete(routeRequest(model: model, wantsStream: true))

    guard case .streaming(_, let contentType, let rebuilt, let appendDone, _) = result else {
      return XCTFail("expected streaming result")
    }
    XCTAssertEqual(contentType, "text/event-stream")
    XCTAssertFalse(appendDone)
    XCTAssertTrue(server.lastRequest?.stream ?? false)

    var assembled = Data()
    for try await event in rebuilt {
      guard case .rawBytes(let bytes) = event else {
        return XCTFail("expected rawBytes")
      }
      assembled.append(bytes)
    }
    XCTAssertTrue(String(data: assembled, encoding: .utf8)?.contains("frame") ?? false)
    XCTAssertTrue(String(data: assembled, encoding: .utf8)?.contains("[DONE]") ?? false)
  }

  func testTypedHostFailureSurfacesAsVideoChatBackendError() async {
    let model = videoModel()
    let server = FakeModelServer(modelID: model.id, sizeBytes: model.sizeBytes) { request in
      [
        VideoFrameCodec.encodeFailure(
          VideoChatBackendError.notConfigured, requestID: request.requestID)
      ]
    }
    let backend = XPCVideoChatBackend { _ in server }
    do {
      _ = try await backend.complete(routeRequest(model: model, wantsStream: false))
      XCTFail("expected notConfigured error")
    } catch let error as VideoChatBackendError {
      XCTAssertEqual(error, .notConfigured)
    } catch {
      XCTFail("expected VideoChatBackendError, got \(error)")
    }
  }

  func testModelMissingSamplingFPSRejectedBeforeDial() async {
    let model = ModelDescriptor(
      id: "/models/video",
      displayName: "Video",
      path: "/models/video",
      kind: .chat,
      capabilities: ModelCapabilities(video: true, videoSamplingFPS: nil)
    )
    let launchCounter = Counter()
    let backend = XPCVideoChatBackend { _ in
      await launchCounter.increment()
      return FakeModelServer(modelID: model.id, sizeBytes: 0) { _ in [] }
    }
    do {
      _ = try await backend.complete(routeRequest(model: model, wantsStream: false))
      XCTFail("expected modelMissingVideoSamplingFPS error")
    } catch let error as VideoChatBackendError {
      XCTAssertEqual(error, .modelMissingVideoSamplingFPS(modelID: "/models/video"))
    } catch {
      XCTFail("expected VideoChatBackendError, got \(error)")
    }
    let launchCount = await launchCounter.value
    XCTAssertEqual(launchCount, 0, "must not spawn a host for a model with no sampling rate")
  }

  func testReusesOneHostAcrossRequestsForTheSameModel() async throws {
    let model = videoModel()
    let launchCounter = Counter()
    let encoded = try await VideoFrameCodec.encode(
      result: .buffered(statusCode: 200, contentType: "application/json", body: Data()),
      requestID: UUID()
    )
    let server = FakeModelServer(modelID: model.id, sizeBytes: model.sizeBytes) { request in
      encoded.map { frame in rekey(frame, to: request.requestID) }
    }
    let backend = XPCVideoChatBackend { _ in
      await launchCounter.increment()
      return server
    }
    _ = try await backend.complete(routeRequest(model: model, wantsStream: false))
    _ = try await backend.complete(routeRequest(model: model, wantsStream: false))
    let count = await launchCounter.value
    XCTAssertEqual(count, 1)
  }
}

private actor Counter {
  private(set) var value = 0
  func increment() { value += 1 }
}

private func rekey(_ frame: BackendFrame, to requestID: UUID) -> BackendFrame {
  switch frame {
  case .chunk(_, let data):
    return .chunk(requestID: requestID, data: data)
  case .done:
    return .done(requestID: requestID)
  case .failed(_, let message):
    return .failed(requestID: requestID, message: message)
  default:
    return frame
  }
}
