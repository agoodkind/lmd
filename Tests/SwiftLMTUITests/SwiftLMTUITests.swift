//
//  SwiftLMTUITests.swift
//  SwiftLMTUITests
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-04-18.
//  Copyright © 2026, all rights reserved.
//

import XCTest
@testable import SwiftLMTUI

final class SwiftLMTUITests: XCTestCase {
  func testVersionIsNonEmpty() {
    XCTAssertFalse(SwiftLMTUI.version.isEmpty)
  }
}
