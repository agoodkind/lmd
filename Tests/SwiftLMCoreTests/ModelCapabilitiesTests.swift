//
//  ModelCapabilitiesTests.swift
//  SwiftLMCoreTests
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-05-09.
//  Copyright © 2026, all rights reserved.
//

import Nimble
import XCTest

@testable import SwiftLMCore

final class ModelCapabilitiesTests: XCTestCase {
  func testDescriptorDefaultsToTextOnlyCapabilities() {
    let descriptor = ModelDescriptor(
      id: "model",
      displayName: "Model",
      path: "/tmp/model"
    )

    expect(descriptor.capabilities) == .textOnly
    expect(descriptor.capabilities.text) == true
    expect(descriptor.capabilities.vision) == false
    expect(descriptor.capabilities.video) == false
  }

  func testCapabilitiesEncodeStableJSONKeys() throws {
    let capabilities = ModelCapabilities(text: true, vision: true, video: true)
    let data = try JSONEncoder().encode(capabilities)
    let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]

    expect(object?["text"] as? Bool) == true
    expect(object?["vision"] as? Bool) == true
    expect(object?["video"] as? Bool) == true
    expect(object?["video_sampling_fps"]) == nil
  }

  func testVideoSamplingFPSRoundTripsThroughJSON() throws {
    let capabilities = ModelCapabilities(
      text: true, vision: true, video: true, videoSamplingFPS: 2.0
    )
    let data = try JSONEncoder().encode(capabilities)
    let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    expect(object?["video_sampling_fps"] as? Double) == 2.0

    let decoded = try JSONDecoder().decode(ModelCapabilities.self, from: data)
    expect(decoded) == capabilities
    expect(decoded.videoSamplingFPS) == 2.0
  }
}
