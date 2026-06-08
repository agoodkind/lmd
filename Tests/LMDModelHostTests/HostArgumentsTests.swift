import SwiftLMHostProtocol
import XCTest

@testable import lmd_model_host

final class HostArgumentsTests: XCTestCase {
  func testParsesAllFields() {
    let args = HostArguments.parse([
      "--model", "/models/arctic",
      "--kind", "embedding",
      "--host-service", "io.goodkind.lmd.host",
    ])
    XCTAssertEqual(args?.modelPath, "/models/arctic")
    XCTAssertEqual(args?.kind, .embedding)
    XCTAssertEqual(args?.hostService, "io.goodkind.lmd.host")
    XCTAssertNil(args?.swiftLMBinaryPath)
    XCTAssertNil(args?.swiftLMLogPath)
    XCTAssertNil(args?.contextLength)
    XCTAssertNil(args?.videoSamplingFPS)
  }

  func testParsesVideoSamplingFPS() {
    let args = HostArguments.parse([
      "--model", "/models/qwen-vl",
      "--kind", "video",
      "--host-service", "io.goodkind.lmd.host",
      "--video-sampling-fps", "2.0",
    ])
    XCTAssertEqual(args?.modelPath, "/models/qwen-vl")
    XCTAssertEqual(args?.kind, .video)
    XCTAssertEqual(args?.videoSamplingFPS, 2.0)
  }

  func testParsesChatSwiftLMFields() {
    let args = HostArguments.parse([
      "--model", "/models/qwen",
      "--kind", "chat",
      "--host-service", "io.goodkind.lmd.host",
      "--swiftlm-binary", "/usr/local/bin/SwiftLM",
      "--swiftlm-log-path", "/tmp/swiftlm.log",
      "--context-length", "8192",
    ])
    XCTAssertEqual(args?.modelPath, "/models/qwen")
    XCTAssertEqual(args?.kind, .chat)
    XCTAssertEqual(args?.swiftLMBinaryPath, "/usr/local/bin/SwiftLM")
    XCTAssertEqual(args?.swiftLMLogPath, "/tmp/swiftlm.log")
    XCTAssertEqual(args?.contextLength, 8_192)
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
