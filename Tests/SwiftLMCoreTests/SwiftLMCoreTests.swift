//
//  SwiftLMCoreTests.swift
//  SwiftLMCoreTests
//
//  Created by Alex Goodkind <alex@goodkind.io> on 2026-04-18.
//  Copyright © 2026
//

import XCTest
@testable import SwiftLMCore

final class SwiftLMCoreTests: XCTestCase {
  func testVersionIsNonEmpty() {
    XCTAssertFalse(SwiftLMCore.version.isEmpty)
  }
}
