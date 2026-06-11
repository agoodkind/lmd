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

  func testParsesEmbeddingTuningFlags() {
    let args = HostArguments.parse([
      "--model", "/m", "--kind", "embedding", "--host-service", "svc",
      "--mlx-cache-limit-bytes", "8589934592",
      "--embed-slot-budget", "23552",
      "--embed-max-rows", "256",
      "--embed-priority-max-inputs", "2",
      "--embed-priority-max-tokens", "2048",
      "--embed-priority-lane", "1",
      "--embed-max-forwards", "1",
    ])
    expect(args?.mlxCacheLimitBytes) == 8_589_934_592
    expect(args?.embedSlotBudget) == 23_552
    expect(args?.embedMaxRows) == 256
    expect(args?.embedPriorityMaxInputs) == 2
    expect(args?.embedPriorityMaxTokens) == 2_048
    expect(args?.embedPriorityLane) == true
    expect(args?.embedMaxForwards) == 1
  }

  func testEmbeddingTuningFlagsAreOptional() {
    let args = HostArguments.parse([
      "--model", "/m", "--kind", "embedding", "--host-service", "svc",
    ])
    expect(args).toNot(beNil())
    expect(args?.mlxCacheLimitBytes).to(beNil())
    expect(args?.embedSlotBudget).to(beNil())
    expect(args?.embedPriorityLane) == true
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
