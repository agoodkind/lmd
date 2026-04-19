//
//  KeyParserTests.swift
//  SwiftLMTUITests
//
//  Created by Alex Goodkind <alex@goodkind.io> on 2026-04-18.
//  Copyright © 2026
//

import XCTest
@testable import SwiftLMTUI

final class KeyParserTests: XCTestCase {
  private func parse(_ s: String) -> KeyEvent {
    let bytes = Array(s.utf8)
    return KeyParser.parse(bytes, start: 0, length: bytes.count)
  }

  private func parseByte(_ b: UInt8) -> KeyEvent {
    KeyParser.parse([b], start: 0, length: 1)
  }

  func testLetterKeys() {
    XCTAssertEqual(parse("j"), .scrollDown)
    XCTAssertEqual(parse("k"), .scrollUp)
    XCTAssertEqual(parse("g"), .top)
    XCTAssertEqual(parse("G"), .bottom)
    XCTAssertEqual(parse("q"), .quit)
    XCTAssertEqual(parse(" "), .pageDown)
  }

  func testControlC() {
    XCTAssertEqual(parseByte(0x03), .quit)
  }

  func testArrowKeys() {
    XCTAssertEqual(parse("\u{001B}[A"), .scrollUp)
    XCTAssertEqual(parse("\u{001B}[B"), .scrollDown)
  }

  func testPageKeys() {
    XCTAssertEqual(parse("\u{001B}[5"), .pageUp)
    XCTAssertEqual(parse("\u{001B}[6"), .pageDown)
  }

  func testUnknownBytesAlwaysAdvance() {
    let ev = parse("Z")
    XCTAssertTrue(ev.consumed >= 1)
  }

  func testIncompleteCSIDoesNotCrash() {
    let bytes: [UInt8] = [0x1B, 0x5B]  // missing third byte
    let ev = KeyParser.parse(bytes, start: 0, length: bytes.count)
    if case .unknown = ev {} else {
      XCTFail("incomplete CSI should map to .unknown, got \(ev)")
    }
  }
}
