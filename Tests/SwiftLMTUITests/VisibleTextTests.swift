//
//  VisibleTextTests.swift
//  SwiftLMTUITests
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-04-18.
//  Copyright © 2026, all rights reserved.
//

import Nimble
import XCTest

@testable import SwiftLMTUI

final class VisibleTextTests: XCTestCase {
  func testWidthIgnoresEscapes() {
    let colorful = "\u{001B}[32mstatus\u{001B}[0m"
    expect(VisibleText.width(colorful)) == 6
  }

  func testPadReachesTargetWidth() {
    let padded = VisibleText.pad("hi", 5)
    expect(padded) == "hi   "
  }

  func testPadLeavesWiderAlone() {
    expect(VisibleText.pad("hello", 3)) == "hello"
  }

  func testTruncateClipsAtVisibleWidth() {
    let s = "abcdefghij"
    expect(VisibleText.truncate(s, 4)) == "abcd" + Ansi.reset
  }

  func testTruncatePreservesEscapesUpToCut() {
    // First 3 visible chars are green, then we cut at 3.
    let s = "\u{001B}[32mabc\u{001B}[0mdef"
    let cut = VisibleText.truncate(s, 3)
    expect(cut.hasPrefix("\u{001B}[32mabc")) == true
    expect(cut.hasSuffix(Ansi.reset)) == true
  }

  func testTruncateLeavesShorterAlone() {
    expect(VisibleText.truncate("hi", 5)) == "hi"
  }
}
