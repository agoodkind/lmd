//
//  VideoFrameSamplingTests.swift
//  SwiftLMBackendTests
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-05-10.
//  Copyright © 2026, all rights reserved.
//

import Foundation
import XCTest

@testable import SwiftLMBackend

final class VideoFrameSamplingTests: XCTestCase {
  func testSamplesAtLeastOneFrameFromOneFrameFixture() async throws {
    let fixtureURL = try fixtureURL("red_32x32_1f.mp4")

    let frames = try await sampledVideoFrames(originalURL: fixtureURL, targetFPS: 2.0)

    XCTAssertGreaterThanOrEqual(frames.count, 1)
  }

  func testSamplesMultipleFramesFromTwoSecondFixture() async throws {
    let fixtureURL = try fixtureURL("red_32x32_2s.mp4")

    let frames = try await sampledVideoFrames(originalURL: fixtureURL, targetFPS: 2.0)

    XCTAssertGreaterThanOrEqual(frames.count, 2)
  }

  func testHonorsMaxFramesCap() async throws {
    let fixtureURL = try fixtureURL("red_32x32_2s.mp4")

    let frames = try await sampledVideoFrames(
      originalURL: fixtureURL, targetFPS: 30.0, maxFrames: 2
    )

    XCTAssertEqual(frames.count, 2)
  }

  func testRejectsInvalidTargetFPS() async throws {
    let fixtureURL = try fixtureURL("red_32x32_1f.mp4")
    do {
      _ = try await sampledVideoFrames(originalURL: fixtureURL, targetFPS: 0)
      XCTFail("expected invalidTargetFPS")
    } catch VideoFrameSamplingError.invalidTargetFPS {
      // expected
    }
  }

  private func fixtureURL(_ name: String) throws -> URL {
    let thisFile = URL(fileURLWithPath: #filePath)
    let repoRoot =
      thisFile
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let candidate = repoRoot.appendingPathComponent(name)
    guard FileManager.default.fileExists(atPath: candidate.path) else {
      throw XCTSkip("fixture missing at \(candidate.path)")
    }
    return candidate
  }
}
