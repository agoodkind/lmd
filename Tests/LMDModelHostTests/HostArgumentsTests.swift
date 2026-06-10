import Nimble
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
    expect(args?.modelPath) == "/models/arctic"
    expect(args?.kind) == .embedding
    expect(args?.hostService) == "io.goodkind.lmd.host"
    expect(args?.swiftLMBinaryPath) == nil
    expect(args?.swiftLMLogPath) == nil
    expect(args?.contextLength) == nil
    expect(args?.videoSamplingFPS) == nil
  }

  func testParsesVideoSamplingFPS() {
    let args = HostArguments.parse([
      "--model", "/models/qwen-vl",
      "--kind", "video",
      "--host-service", "io.goodkind.lmd.host",
      "--video-sampling-fps", "2.0",
    ])
    expect(args?.modelPath) == "/models/qwen-vl"
    expect(args?.kind) == .video
    expect(args?.videoSamplingFPS) == 2.0
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
    expect(args?.modelPath) == "/models/qwen"
    expect(args?.kind) == .chat
    expect(args?.swiftLMBinaryPath) == "/usr/local/bin/SwiftLM"
    expect(args?.swiftLMLogPath) == "/tmp/swiftlm.log"
    expect(args?.contextLength) == 8_192
  }

  func testRejectsUnknownKind() {
    let args = HostArguments.parse([
      "--model", "/m", "--kind", "bogus", "--host-service", "s",
    ])
    expect(args) == nil
  }

  func testRejectsMissingField() {
    let args = HostArguments.parse(["--model", "/m", "--kind", "chat"])
    expect(args) == nil
  }
}
