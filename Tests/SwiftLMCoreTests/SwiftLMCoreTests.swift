//
//  SwiftLMCoreTests.swift
//  SwiftLMCoreTests
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-04-18.
//  Copyright © 2026, all rights reserved.
//

import Nimble
import XCTest

@testable import SwiftLMCore

final class SwiftLMCoreTests: XCTestCase {
  func testVersionIsNonEmpty() {
    expect(SwiftLMCore.version.isEmpty) == false
  }
}
