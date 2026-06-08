import XCTest

@testable import SwiftLMHostProtocol

final class FramesTests: XCTestCase {
  private func roundTrip<T: Codable & Equatable>(_ value: T) throws -> T {
    let data = try JSONEncoder().encode(value)
    return try JSONDecoder().decode(T.self, from: data)
  }

  func testBackendRequestRoundTrips() throws {
    let id = UUID()
    let req = BackendRequest(
      requestID: id,
      kind: .chat,
      openAIBody: Data([1, 2, 3]),
      stream: true,
      endpointPath: "/v1/chat/completions",
      headers: ["X-LMD-Request-ID": id.uuidString]
    )
    XCTAssertEqual(try roundTrip(req), req)
  }

  func testEveryFrameCaseRoundTrips() throws {
    let id = UUID()
    let frames: [BackendFrame] = [
      .hello(spawnToken: "tok-123"),
      .ready,
      .responseStarted(requestID: id, statusCode: 200, contentType: "text/event-stream"),
      .chunk(requestID: id, data: Data("data: {}\n\n".utf8)),
      .vectors(requestID: id, dims: 2, payload: Data([0, 0, 0, 0, 0, 0, 128, 63])),
      .usage(requestID: id, promptTokens: 9, completionTokens: 2),
      .done(requestID: id),
      .failed(requestID: id, message: "boom"),
      .stats(rssBytes: 1_024, gpuActiveBytes: 2_048, gpuCacheBytes: 512),
      .metricsSnapshot(Data("{}".utf8)),
    ]
    for frame in frames {
      XCTAssertEqual(try roundTrip(frame), frame, "frame \(frame) did not round-trip")
    }
  }

  func testThrottleLevelRoundTrips() throws {
    for level in [ThrottleLevel.none, .mild, .hard] {
      XCTAssertEqual(try roundTrip(level), level, "level \(level) did not round-trip")
    }
  }

  func testHostInboundRequestRoundTrips() throws {
    let req = BackendRequest(
      requestID: UUID(), kind: .embedding, openAIBody: Data([4, 5, 6]), stream: false)
    let inbound = HostInbound.request(req)
    XCTAssertEqual(try roundTrip(inbound), inbound)
  }

  func testHostInboundControlRoundTrips() throws {
    for level in [ThrottleLevel.none, .mild, .hard] {
      let inbound = HostInbound.control(.applyPowerThrottle(level))
      XCTAssertEqual(try roundTrip(inbound), inbound, "control \(level) did not round-trip")
    }
  }
}
