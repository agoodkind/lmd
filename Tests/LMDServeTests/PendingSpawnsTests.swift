import XCTest

@testable import LMDServeSupport

final class PendingSpawnsTests: XCTestCase {
  func testRegisterThenClaimReturnsModelID() async {
    let registry = PendingSpawns()
    await registry.register(token: "t1", modelID: "m1")
    let claimed = await registry.claim(token: "t1")
    XCTAssertEqual(claimed, "m1")
  }

  func testClaimUnknownTokenReturnsNil() async {
    let registry = PendingSpawns()
    let claimed = await registry.claim(token: "missing")
    XCTAssertNil(claimed)
  }

  func testClaimIsSingleUse() async {
    let registry = PendingSpawns()
    await registry.register(token: "t1", modelID: "m1")
    _ = await registry.claim(token: "t1")
    let second = await registry.claim(token: "t1")
    XCTAssertNil(second)
  }
}
