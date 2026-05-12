//
//  ModelCapabilitiesTests.swift
//  SwiftLMCoreTests
//
//  Created by Alex Goodkind <alex@goodkind.io> on 2026-05-09.
//  Copyright © 2026
//

import XCTest

@testable import SwiftLMCore

final class ModelCapabilitiesTests: XCTestCase {
  func testDescriptorDefaultsToTextOnlyCapabilities() {
    let descriptor = ModelDescriptor(
      id: "model",
      displayName: "Model",
      path: "/tmp/model"
    )

    XCTAssertEqual(descriptor.capabilities, .textOnly)
    XCTAssertTrue(descriptor.capabilities.text)
    XCTAssertFalse(descriptor.capabilities.vision)
    XCTAssertFalse(descriptor.capabilities.video)
  }

  func testCapabilitiesEncodeStableJSONKeys() throws {
    let capabilities = ModelCapabilities(text: true, vision: true, video: true)
    let data = try JSONEncoder().encode(capabilities)
    let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]

    XCTAssertEqual(object?["text"] as? Bool, true)
    XCTAssertEqual(object?["vision"] as? Bool, true)
    XCTAssertEqual(object?["video"] as? Bool, true)
    XCTAssertNil(object?["video_sampling_fps"])
  }

  func testVideoSamplingFPSRoundTripsThroughJSON() throws {
    let capabilities = ModelCapabilities(
      text: true, vision: true, video: true, videoSamplingFPS: 2.0
    )
    let data = try JSONEncoder().encode(capabilities)
    let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    XCTAssertEqual(object?["video_sampling_fps"] as? Double, 2.0)

    let decoded = try JSONDecoder().decode(ModelCapabilities.self, from: data)
    XCTAssertEqual(decoded, capabilities)
    XCTAssertEqual(decoded.videoSamplingFPS, 2.0)
  }
}
