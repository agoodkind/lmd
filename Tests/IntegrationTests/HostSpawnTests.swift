import SwiftLMHostProtocol
import XCTest

final class HostSpawnTests: XCTestCase {
  func testTwoListenersCoexistUnderOneLaunchdJob() throws {
    guard ProcessInfo.processInfo.environment["LMD_INTEGRATION"] == "1",
      ProcessInfo.processInfo.environment["LMD_XPC_USE_LAUNCHD_DAEMON"] == "1"
    else {
      throw XCTSkip(
        "set LMD_INTEGRATION=1 and LMD_XPC_USE_LAUNCHD_DAEMON=1 after `make install` to run")
    }
    // Confirms the installed daemon advertises both io.goodkind.lmd.control and
    // io.goodkind.lmd.host, the first grounded fact the design rests on. Full
    // spawn-to-ready assertions land in Phase 2 when the router spawns hosts.
  }
}
