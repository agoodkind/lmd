//
//  LayoutTests.swift
//  SwiftLMTUITests
//
//  Created by Alex Goodkind <alex@goodkind.io> on 2026-04-18.
//  Copyright © 2026
//

import XCTest
@testable import SwiftLMTUI

final class LayoutTests: XCTestCase {
  func testRowThreeAligns() {
    let r = Row.three("cpu", "42°C", ">>>bars<<<")
    // "  " (indent) + "cpu" padded to 12 + "  " gap + "42°C" padded to 12 + "  " gap + extra
    XCTAssertEqual(
      VisibleText.width(r),
      2 + 12 + 2 + 12 + 2 + VisibleText.width(">>>bars<<<")
    )
  }

  func testProgressBarClampsHigh() {
    let bar = ProgressBar.render(percent: 200, width: 10, color: Theme.ok)
    XCTAssertEqual(VisibleText.width(bar), 10)
  }

  func testProgressBarClampsLow() {
    let bar = ProgressBar.render(percent: -50, width: 10, color: Theme.ok)
    XCTAssertEqual(VisibleText.width(bar), 10)
  }

  func testProgressBarZeroPercent() {
    let bar = ProgressBar.render(percent: 0, width: 5, color: Theme.ok)
    XCTAssertEqual(VisibleText.width(bar), 5)
  }
}
