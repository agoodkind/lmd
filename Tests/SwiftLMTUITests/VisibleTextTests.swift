//
//  VisibleTextTests.swift
//  SwiftLMTUITests
//
//  Created by Alex Goodkind <alex@goodkind.io> on 2026-04-18.
//  Copyright © 2026
//

import XCTest
@testable import SwiftLMTUI

final class VisibleTextTests: XCTestCase {
  func testWidthIgnoresEscapes() {
    let colorful = "\u{001B}[32mstatus\u{001B}[0m"
    XCTAssertEqual(VisibleText.width(colorful), 6)
  }

  func testPadReachesTargetWidth() {
    let padded = VisibleText.pad("hi", 5)
    XCTAssertEqual(padded, "hi   ")
  }

  func testPadLeavesWiderAlone() {
    XCTAssertEqual(VisibleText.pad("hello", 3), "hello")
  }

  func testTruncateClipsAtVisibleWidth() {
    let s = "abcdefghij"
    XCTAssertEqual(VisibleText.truncate(s, 4), "abcd" + Ansi.reset)
  }

  func testTruncatePreservesEscapesUpToCut() {
    // First 3 visible chars are green, then we cut at 3.
    let s = "\u{001B}[32mabc\u{001B}[0mdef"
    let cut = VisibleText.truncate(s, 3)
    XCTAssertTrue(cut.hasPrefix("\u{001B}[32mabc"))
    XCTAssertTrue(cut.hasSuffix(Ansi.reset))
  }

  func testTruncateLeavesShorterAlone() {
    XCTAssertEqual(VisibleText.truncate("hi", 5), "hi")
  }
}
