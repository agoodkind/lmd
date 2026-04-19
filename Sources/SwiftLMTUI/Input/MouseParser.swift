//
//  MouseParser.swift
//  SwiftLMTUI
//
//  Created by Alex Goodkind <alex@goodkind.io> on 2026-04-18.
//  Copyright © 2026
//

import Foundation

// MARK: - Mouse parser

/// One SGR mouse event decoded off the terminal byte stream.
public struct SGRMouseEvent: Equatable, Sendable {
  /// Button code. Wheel-up is 64, wheel-down is 65. Left press is 0, etc.
  public let button: Int
  /// 1-based column of the pointer at event time.
  public let column: Int
  /// 1-based row of the pointer at event time.
  public let row: Int
  /// `true` if this was a press, `false` for release.
  public let pressed: Bool
  /// Number of bytes consumed from the input buffer.
  public let consumed: Int
}

/// Parser for SGR-mode (`CSI ?1006h`) mouse escape sequences.
///
/// Sequences have the form `ESC [ < btn ; x ; y (M|m)` where `M`
/// terminates a press event and `m` terminates a release. The terminal
/// sends this encoding when both `?1006h` and `?1002h` are enabled.
public enum MouseParser {
  /// Attempt to parse one SGR mouse event starting at `start` in `buffer`.
  ///
  /// - Parameters:
  ///   - buffer: Raw byte buffer containing terminal input.
  ///   - start: Index in `buffer` where the escape sequence begins.
  ///   - length: The number of valid bytes in `buffer`. Reads never go
  ///     past this bound even if the buffer's `count` is larger.
  /// - Returns: The parsed event, or `nil` if the bytes at `start` do not
  ///   form a complete SGR mouse sequence.
  public static func parse(_ buffer: [UInt8], start: Int, length: Int) -> SGRMouseEvent? {
    guard start + 3 < length else { return nil }
    guard
      buffer[start] == 0x1B,
      buffer[start + 1] == 0x5B,    // [
      buffer[start + 2] == 0x3C     // <
    else { return nil }

    var i = start + 3

    func readNumber() -> Int? {
      var value = 0
      var any = false
      while i < length, buffer[i] >= 0x30, buffer[i] <= 0x39 {
        value = value * 10 + Int(buffer[i] - 0x30)
        i += 1
        any = true
      }
      return any ? value : nil
    }

    guard let button = readNumber() else { return nil }
    guard i < length, buffer[i] == 0x3B else { return nil }  // ;
    i += 1
    guard let x = readNumber() else { return nil }
    guard i < length, buffer[i] == 0x3B else { return nil }
    i += 1
    guard let y = readNumber() else { return nil }
    guard i < length else { return nil }
    let terminator = buffer[i]
    guard terminator == UInt8(ascii: "M") || terminator == UInt8(ascii: "m") else { return nil }
    let pressed = terminator == UInt8(ascii: "M")
    return SGRMouseEvent(
      button: button,
      column: x,
      row: y,
      pressed: pressed,
      consumed: (i + 1) - start
    )
  }
}

// MARK: - Well-known buttons

extension SGRMouseEvent {
  /// Wheel up event button code.
  public static let wheelUpButton = 64
  /// Wheel down event button code.
  public static let wheelDownButton = 65
  /// Convenience: is this a wheel-up press?
  public var isWheelUp: Bool { pressed && button == Self.wheelUpButton }
  /// Convenience: is this a wheel-down press?
  public var isWheelDown: Bool { pressed && button == Self.wheelDownButton }
}
