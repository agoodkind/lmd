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
    let object = try JSONSerialization.jsonObject(with: data) as? [String: Bool]

    XCTAssertEqual(object, ["text": true, "vision": true, "video": true])
  }
}
