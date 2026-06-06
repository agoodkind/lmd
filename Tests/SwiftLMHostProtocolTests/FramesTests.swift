import XCTest
@testable import SwiftLMHostProtocol

final class FramesTests: XCTestCase {
  private func roundTrip<T: Codable & Equatable>(_ value: T) throws -> T {
    let data = try JSONEncoder().encode(value)
    return try JSONDecoder().decode(T.self, from: data)
  }

  func testBackendRequestRoundTrips() throws {
    let id = UUID()
    let req = BackendRequest(requestID: id, kind: .embedding, openAIBody: Data([1, 2, 3]), stream: false)
    XCTAssertEqual(try roundTrip(req), req)
  }

  func testEveryFrameCaseRoundTrips() throws {
    let id = UUID()
    let frames: [BackendFrame] = [
      .hello(spawnToken: "tok-123"),
      .ready,
      .chunk(requestID: id, data: Data("data: {}\n\n".utf8)),
      .vectors(requestID: id, dims: 2, payload: Data([0, 0, 0, 0, 0, 0, 128, 63])),
      .usage(requestID: id, promptTokens: 9, completionTokens: 2),
      .done(requestID: id),
      .failed(requestID: id, message: "boom"),
      .stats(rssBytes: 1024, gpuActiveBytes: 2048, gpuCacheBytes: 512),
      .metricsSnapshot(Data("{}".utf8)),
    ]
    for frame in frames {
      XCTAssertEqual(try roundTrip(frame), frame, "frame \(frame) did not round-trip")
    }
  }
}
