import Foundation
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
  private(set) var lastRequest: BackendRequest?
  private(set) var didSpawn = false
  private(set) var didWaitReady = false
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

  func spawn() async throws {
    didSpawn = true
  }

  func waitReady() async throws {
    didWaitReady = true
  }

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

  func shutdown() {
    didShutdown = true
    isRunning = false
  }
}

private final class CleanupCounter: @unchecked Sendable {
  private let lock = NSLock()
  private var count = 0

  func increment() {
    lock.lock()
    count += 1
    lock.unlock()
  }

  func value() -> Int {
    lock.lock()
    defer { lock.unlock() }
    return count
  }
}

final class XPCChatBackendTests: XCTestCase {
  func testBufferedResponseRoundTripsBodyAndRequestMetadata() async throws {
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
    let backend = XPCChatBackend(server: server, port: 5500)
    let requestID = UUID()

    let result = try await backend.complete(
      preparedRequest(endpoint: .completions, wantsStream: false),
      requestID: requestID,
      headers: ["X-LMD-Request-ID": requestID.uuidString]
    )

    guard case .buffered(let statusCode, let contentType, let decodedBody) = result else {
      return XCTFail("expected buffered result")
    }
    XCTAssertEqual(statusCode, 201)
    XCTAssertEqual(contentType, "application/json")
    XCTAssertEqual(decodedBody, body)
    XCTAssertEqual(server.lastRequest?.requestID, requestID)
    XCTAssertEqual(server.lastRequest?.kind, .chat)
    XCTAssertEqual(server.lastRequest?.endpointPath, "/v1/completions")
    XCTAssertEqual(server.lastRequest?.openAIBody, requestBody(stream: false))
    XCTAssertFalse(server.lastRequest?.stream ?? true)
    XCTAssertEqual(server.lastRequest?.headers["X-LMD-Request-ID"], requestID.uuidString)
  }

  func testStreamingResponseYieldsRawBytesAndMetadata() async throws {
    let first = Data("data: {\"delta\":\"hel\"}\n\n".utf8)
    let second = Data("data: [DONE]\n\n".utf8)
    let server = FakeModelServer(modelID: "model-a", sizeBytes: 42) { request in
      [
        .responseStarted(
          requestID: request.requestID,
          statusCode: 200,
          contentType: "text/event-stream; charset=utf-8"
        ),
        .chunk(requestID: request.requestID, data: first),
        .chunk(requestID: request.requestID, data: second),
        .done(requestID: request.requestID),
      ]
    }
    let backend = XPCChatBackend(server: server, port: 5500)

    let result = try await backend.complete(
      preparedRequest(endpoint: .chatCompletions, wantsStream: true),
      requestID: UUID(),
      headers: ["Accept": "text/event-stream"]
    )

    guard case .streaming(let statusCode, let contentType, let events, let appendDone, _) = result
    else {
      return XCTFail("expected streaming result")
    }
    XCTAssertEqual(statusCode, 200)
    XCTAssertEqual(contentType, "text/event-stream; charset=utf-8")
    XCTAssertFalse(appendDone)
    XCTAssertEqual(server.lastRequest?.endpointPath, "/v1/chat/completions")
    XCTAssertTrue(server.lastRequest?.stream ?? false)
    XCTAssertEqual(server.lastRequest?.headers["Accept"], "text/event-stream")

    var assembled = Data()
    for try await event in events {
      guard case .rawBytes(let data) = event else {
        return XCTFail("expected raw bytes")
      }
      assembled.append(data)
    }
    var expected = Data()
    expected.append(first)
    expected.append(second)
    XCTAssertEqual(assembled, expected)
  }

  func testFailedFrameThrowsHostFailed() async {
    let server = FakeModelServer(modelID: "model-a", sizeBytes: 42) { request in
      [.failed(requestID: request.requestID, message: "boom")]
    }
    let backend = XPCChatBackend(server: server, port: 5500)

    do {
      _ = try await backend.complete(
        preparedRequest(endpoint: .chatCompletions, wantsStream: false),
        requestID: UUID(),
        headers: [:]
      )
      XCTFail("expected host failed error")
    } catch let error as XPCChatBackendError {
      XCTAssertEqual(error, .hostFailed(message: "boom"))
    } catch {
      XCTFail("expected XPCChatBackendError, got \(error)")
    }
  }

  func testLaunchAndShutdownForwardToServer() throws {
    let server = FakeModelServer(modelID: "model-a", sizeBytes: 42) { _ in [] }
    let cleanupCounter = CleanupCounter()
    let backend = XPCChatBackend(server: server, port: 5500) {
      cleanupCounter.increment()
    }

    try backend.launch()
    XCTAssertTrue(server.didSpawn)
    XCTAssertTrue(server.didWaitReady)
    XCTAssertTrue(backend.isRunning)

    backend.shutdown()
    XCTAssertTrue(server.didShutdown)
    XCTAssertFalse(backend.isRunning)
    XCTAssertEqual(cleanupCounter.value(), 1)
  }

  private func preparedRequest(
    endpoint: OpenAIChatEndpoint,
    wantsStream: Bool
  ) -> PreparedChatRequest {
    PreparedChatRequest(
      endpoint: endpoint,
      bodyData: requestBody(stream: wantsStream),
      json: ["model": "model-a"],
      model: ModelDescriptor(
        id: "model-a",
        displayName: "Model A",
        path: "/models/model-a",
        sizeBytes: 42
      ),
      wantsStream: wantsStream,
      mediaInspection: OpenAIVideoInspection(videos: [])
    )
  }
}

private func requestBody(stream: Bool) -> Data {
  if stream {
    return Data(#"{"model":"model-a","messages":[],"stream":true}"#.utf8)
  }
  return Data(#"{"model":"model-a","prompt":"hello","stream":false}"#.utf8)
}
