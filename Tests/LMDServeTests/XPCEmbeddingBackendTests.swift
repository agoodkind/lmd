import SwiftLMCore
import SwiftLMHostProtocol
import SwiftLMRuntime
import XCTest

@testable import LMDServeSupport

/// A ModelServer that never spawns a process. It replays a scripted frame
/// sequence for each request so the adapter's stream consumption and decode can
/// be exercised in isolation.
private final class FakeModelServer: ModelServer, @unchecked Sendable {
  let modelID: String
  let sizeBytes: Int64
  private let framesFor: @Sendable (BackendRequest) -> [BackendFrame]
  private let lock = NSLock()
  private var throttleLevels: [ThrottleLevel] = []
  private(set) var didShutdown = false
  private(set) var didSpawn = false

  var appliedThrottleLevels: [ThrottleLevel] {
    lock.lock()
    defer { lock.unlock() }
    return throttleLevels
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

  func spawn() async throws { didSpawn = true }
  func waitReady() async throws {}

  func send(_ request: BackendRequest) -> AsyncThrowingStream<BackendFrame, Error> {
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

  func applyPowerThrottle(_ level: ThrottleLevel) {
    lock.lock()
    throttleLevels.append(level)
    lock.unlock()
  }

  func shutdown() { didShutdown = true }
}

final class XPCEmbeddingBackendTests: XCTestCase {
  func testEmbedRoundTripsVectorsThroughVectorBlob() async throws {
    let expected: [[Float]] = [[1, 2, 3], [-1, 0.5, 4]]
    let server = FakeModelServer(modelID: "/m", sizeBytes: 42) { request in
      let (dims, payload) = VectorBlob.encode(expected)
      return [
        .vectors(requestID: request.requestID, dims: dims, payload: payload),
        .usage(requestID: request.requestID, promptTokens: 0, completionTokens: 0),
        .done(requestID: request.requestID),
      ]
    }
    let backend = XPCEmbeddingBackend(server: server)
    let vectors = try await backend.embed(inputs: ["a", "b"])
    XCTAssertEqual(vectors, expected)
    XCTAssertEqual(backend.modelID, "/m")
    XCTAssertEqual(backend.sizeBytes, 42)
  }

  func testEmbedThrowsOnFailedFrame() async {
    let server = FakeModelServer(modelID: "/m", sizeBytes: 0) { request in
      [.failed(requestID: request.requestID, message: "boom")]
    }
    let backend = XPCEmbeddingBackend(server: server)
    do {
      _ = try await backend.embed(inputs: ["a"])
      XCTFail("expected hostFailed error")
    } catch let error as XPCEmbeddingBackendError {
      XCTAssertEqual(error, .hostFailed(message: "boom"))
    } catch {
      XCTFail("expected XPCEmbeddingBackendError, got \(error)")
    }
  }

  func testEmbedThrowsWhenNoVectorsFrame() async {
    let server = FakeModelServer(modelID: "/m", sizeBytes: 0) { request in
      [.done(requestID: request.requestID)]
    }
    let backend = XPCEmbeddingBackend(server: server)
    do {
      _ = try await backend.embed(inputs: ["a"])
      XCTFail("expected noVectorsReturned error")
    } catch let error as XPCEmbeddingBackendError {
      XCTAssertEqual(error, .noVectorsReturned)
    } catch {
      XCTFail("expected XPCEmbeddingBackendError, got \(error)")
    }
  }

  func testLaunchSpawnsAndShutdownForwards() async throws {
    let server = FakeModelServer(modelID: "/m", sizeBytes: 0) { _ in [] }
    let backend = XPCEmbeddingBackend(server: server)
    try await backend.launch()
    XCTAssertTrue(server.didSpawn)
    backend.shutdown()
    XCTAssertTrue(server.didShutdown)
  }

  func testApplyPowerThrottleForwardsMappedLevelToServer() {
    let server = FakeModelServer(modelID: "/m", sizeBytes: 0) { _ in [] }
    let backend = XPCEmbeddingBackend(server: server)
    backend.applyPowerThrottle(.hard)
    backend.applyPowerThrottle(.mild)
    backend.applyPowerThrottle(.none)
    XCTAssertEqual(server.appliedThrottleLevels, [.hard, .mild, .none])
  }
}
