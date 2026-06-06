import XCTest
@testable import SwiftLMHostProtocol

final class VectorBlobTests: XCTestCase {
  func testRoundTripPreservesVectors() throws {
    let vectors: [[Float]] = [[1, 2, 3], [-1, 0.5, 4]]
    let (dims, payload) = VectorBlob.encode(vectors)
    XCTAssertEqual(dims, 3)
    let decoded = try VectorBlob.decode(dims: dims, payload: payload)
    XCTAssertEqual(decoded, vectors)
  }

  func testEmptyEncodesToZeroDims() {
    let (dims, payload) = VectorBlob.encode([])
    XCTAssertEqual(dims, 0)
    XCTAssertTrue(payload.isEmpty)
  }

  func testRaggedPayloadThrowsOnDecodeMismatch() {
    let bad = Data(repeating: 0, count: 12)  // 12 bytes = 3 floats
    XCTAssertThrowsError(try VectorBlob.decode(dims: 2, payload: bad))
  }
}
