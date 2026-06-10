//
//  MouseParserTests.swift
//  SwiftLMTUITests
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-04-18.
//  Copyright © 2026, all rights reserved.
//

import Nimble
import XCTest

@testable import SwiftLMTUI

final class MouseParserTests: XCTestCase {
  /// Build a byte buffer representing `ESC [ < btn ; x ; y (M|m)`.
  private func sgrBytes(button: Int, x: Int, y: Int, pressed: Bool) -> [UInt8] {
    let terminator = pressed ? "M" : "m"
    let s = "\u{001B}[<\(button);\(x);\(y)\(terminator)"
    return Array(s.utf8)
  }

  func testParsesWheelUpPress() {
    let bytes = sgrBytes(button: 64, x: 42, y: 7, pressed: true)
    let ev = MouseParser.parse(bytes, start: 0, length: bytes.count)
    expect(ev) != nil
    expect(ev?.button) == 64
    expect(ev?.column) == 42
    expect(ev?.row) == 7
    expect(ev?.pressed) == true
    expect(ev?.isWheelUp ?? false) == true
    expect(ev?.consumed) == bytes.count
  }

  func testParsesWheelDownPress() {
    let bytes = sgrBytes(button: 65, x: 1, y: 1, pressed: true)
    let ev = MouseParser.parse(bytes, start: 0, length: bytes.count)
    expect(ev?.isWheelDown ?? false) == true
  }

  func testReleaseIsNotPressed() {
    let bytes = sgrBytes(button: 0, x: 10, y: 20, pressed: false)
    let ev = MouseParser.parse(bytes, start: 0, length: bytes.count)
    expect(ev?.pressed) == false
  }

  func testRejectsWrongPrefix() {
    let bytes: [UInt8] = [0x1B, 0x5B, 0x41]  // CSI A: cursor-up sequence, not mouse
    expect(MouseParser.parse(bytes, start: 0, length: bytes.count)) == nil
  }

  func testRejectsTruncatedSequence() {
    // ESC[<64;42  -- missing ;y(M|m)
    let bytes: [UInt8] = Array("\u{001B}[<64;42".utf8)
    expect(MouseParser.parse(bytes, start: 0, length: bytes.count)) == nil
  }

  func testParsesInsideLargerBuffer() {
    var bytes: [UInt8] = [0x41, 0x42]  // leading junk
    bytes.append(contentsOf: sgrBytes(button: 64, x: 5, y: 9, pressed: true))
    bytes.append(contentsOf: [0x43])  // trailing junk
    let ev = MouseParser.parse(bytes, start: 2, length: bytes.count)
    expect(ev?.button) == 64
    expect(ev?.column) == 5
    expect(ev?.row) == 9
  }
}
