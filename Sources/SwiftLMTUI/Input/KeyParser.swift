//
//  KeyParser.swift
//  SwiftLMTUI
//
//  Created by Alex Goodkind <alex@goodkind.io> on 2026-04-18.
//  Copyright © 2026
//

import Foundation

// MARK: - Keyboard events

/// One keyboard event decoded off the terminal byte stream.
///
/// Events are scoped to the navigation subset this TUI cares about. Any
/// byte sequence that does not match a known control maps to ``unknown``
/// so callers can advance past it without interrupting their parse loop.
public enum KeyEvent: Equatable, Sendable {
  case quit
  case scrollDown
  case scrollUp
  case pageDown
  case pageUp
  case top
  case bottom
  case unknown(consumed: Int)

  /// Number of bytes consumed for this event.
  public var consumed: Int {
    switch self {
    case .quit, .scrollDown, .scrollUp, .top, .bottom: return 1
    case .pageDown, .pageUp: return 3
    case .unknown(let n): return max(1, n)
    }
  }
}

// MARK: - Key parser

/// Parser for a small, well-known set of keystrokes.
///
/// The parser reads up to 3 bytes per event and always makes forward
/// progress. Callers use the returned `consumed` to advance their buffer
/// index so that multiple events queued in a single `read()` can be drained.
public enum KeyParser {
  /// Parse one key event starting at `start` in `buffer`.
  ///
  /// - Returns: A `KeyEvent`. Never returns `nil`. Unparseable bytes map
  ///   to ``KeyEvent/unknown(consumed:)`` with a consumed count of 1.
  public static func parse(_ buffer: [UInt8], start: Int, length: Int) -> KeyEvent {
    guard start < length else { return .unknown(consumed: 1) }
    let ch = buffer[start]

    // Single-byte keys.
    switch ch {
    case 0x03, UInt8(ascii: "q"):
      return .quit
    case UInt8(ascii: "j"):
      return .scrollDown
    case UInt8(ascii: "k"):
      return .scrollUp
    case UInt8(ascii: " "):
      return .pageDown
    case UInt8(ascii: "g"):
      return .top
    case UInt8(ascii: "G"):
      return .bottom
    default:
      break
    }

    // CSI sequences (ESC [ ...).
    if ch == 0x1B, start + 2 < length, buffer[start + 1] == 0x5B {
      let third = buffer[start + 2]
      switch third {
      case UInt8(ascii: "A"): return .scrollUp
      case UInt8(ascii: "B"): return .scrollDown
      case UInt8(ascii: "5"): return .pageUp
      case UInt8(ascii: "6"): return .pageDown
      default: return .unknown(consumed: 3)
      }
    }

    return .unknown(consumed: 1)
  }
}
