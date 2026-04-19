//
//  Visible.swift
//  SwiftLMTUI
//
//  Created by Alex Goodkind <alex@goodkind.io> on 2026-04-18.
//  Copyright © 2026
//

import Foundation

// MARK: - Visible-width helpers

/// Width and padding helpers that respect ANSI escape sequences.
///
/// All functions count only the *visible* character cells. ANSI escape
/// sequences (`\x1B[...`) do not contribute to the measured width. This
/// matters for layout: a colorized label like `"\x1B[32mstatus\x1B[0m"`
/// should occupy 6 columns, not 15.
public enum VisibleText {
  /// Count visible character cells in `s`, skipping ANSI escape sequences.
  public static func width(_ s: String) -> Int {
    var count = 0
    var inEscape = false
    for ch in s {
      if inEscape {
        if ch.isLetter { inEscape = false }
        continue
      }
      if ch == "\u{001B}" {
        inEscape = true
        continue
      }
      count += 1
    }
    return count
  }

  /// Pad `s` with spaces on the right so its visible width equals `width`.
  ///
  /// Returns `s` unchanged if it is already that wide or wider.
  public static func pad(_ s: String, _ width: Int) -> String {
    let need = width - Self.width(s)
    if need <= 0 { return s }
    return s + String(repeating: " ", count: need)
  }

  /// Truncate `s` so its visible width is at most `width`.
  ///
  /// ANSI escape sequences are preserved but do not count toward the
  /// width. Truncation never occurs mid-escape. A terminating `reset`
  /// escape is appended so any open attribute state clears at the cut.
  public static func truncate(_ s: String, _ width: Int) -> String {
    if Self.width(s) <= width { return s }
    var out = ""
    var count = 0
    var inEscape = false
    for ch in s {
      if inEscape {
        out.append(ch)
        if ch.isLetter { inEscape = false }
        continue
      }
      if ch == "\u{001B}" {
        inEscape = true
        out.append(ch)
        continue
      }
      if count >= width { break }
      out.append(ch)
      count += 1
    }
    return out + Ansi.reset
  }
}
