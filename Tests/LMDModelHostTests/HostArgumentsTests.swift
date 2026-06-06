import XCTest
import SwiftLMHostProtocol
@testable import lmd_model_host

final class HostArgumentsTests: XCTestCase {
  func testParsesAllFields() throws {
    let args = HostArguments.parse([
      "--model", "/models/arctic",
      "--kind", "embedding",
      "--host-service", "io.goodkind.lmd.host",
    ])
    XCTAssertEqual(args?.modelPath, "/models/arctic")
    XCTAssertEqual(args?.kind, .embedding)
    XCTAssertEqual(args?.hostService, "io.goodkind.lmd.host")
  }

  func testRejectsUnknownKind() {
    let args = HostArguments.parse([
      "--model", "/m", "--kind", "bogus", "--host-service", "s",
    ])
    XCTAssertNil(args)
  }

  func testRejectsMissingField() {
    let args = HostArguments.parse(["--model", "/m", "--kind", "chat"])
    XCTAssertNil(args)
  }
}
