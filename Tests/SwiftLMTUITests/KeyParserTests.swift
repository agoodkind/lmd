//
//  KeyParserTests.swift
//  SwiftLMTUITests
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-04-18.
//  Copyright © 2026, all rights reserved.
//

import Nimble
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
    expect(self.parse("j")) == .scrollDown
    expect(self.parse("k")) == .scrollUp
    expect(self.parse("g")) == .top
    expect(self.parse("G")) == .bottom
    expect(self.parse("q")) == .quit
    expect(self.parse(" ")) == .pageDown
  }

  func testControlC() {
    expect(self.parseByte(0x03)) == .quit
  }

  func testArrowKeys() {
    expect(self.parse("\u{001B}[A")) == .scrollUp
    expect(self.parse("\u{001B}[B")) == .scrollDown
  }

  func testPageKeys() {
    expect(self.parse("\u{001B}[5")) == .pageUp
    expect(self.parse("\u{001B}[6")) == .pageDown
  }

  func testUnknownBytesAlwaysAdvance() {
    let ev = parse("Z")
    expect(ev.consumed >= 1) == true
  }

  func testIncompleteCSIDoesNotCrash() {
    let bytes: [UInt8] = [0x1B, 0x5B]  // missing third byte
    let ev = KeyParser.parse(bytes, start: 0, length: bytes.count)
    if case .unknown = ev {
    } else {
      fail("incomplete CSI should map to .unknown, got \(ev)")
    }
  }
}
