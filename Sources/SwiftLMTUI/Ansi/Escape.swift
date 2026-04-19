//
//  Escape.swift
//  SwiftLMTUI
//
//  Created by Alex Goodkind <alex@goodkind.io> on 2026-04-18.
//  Copyright © 2026
//

import Foundation

// MARK: - ANSI Escape Sequences

/// Raw ANSI / CSI escape strings used by the TUI.
///
/// Each property is a small, orthogonal primitive. Higher-level helpers
/// (`move`, `fg`, `bg`) compose them into full sequences. The TUI builds
/// its output by concatenating these into a single `String` per frame.
public enum Ansi {
  /// Reset all SGR attributes back to terminal default.
  public static let reset = "\u{001B}[0m"
  /// Bold attribute on.
  public static let bold = "\u{001B}[1m"
  /// Dim attribute on.
  public static let dim = "\u{001B}[2m"

  /// Enter the alternate screen buffer. Pairs with `altOff`.
  public static let altOn = "\u{001B}[?1049h"
  /// Leave the alternate screen buffer.
  public static let altOff = "\u{001B}[?1049l"

  /// Hide the terminal cursor.
  public static let hideCursor = "\u{001B}[?25l"
  /// Show the terminal cursor.
  public static let showCursor = "\u{001B}[?25h"

  /// Disable line wrapping so long lines truncate at the right edge.
  public static let wrapOff = "\u{001B}[?7l"
  /// Re-enable line wrapping.
  public static let wrapOn = "\u{001B}[?7h"

  /// Move the cursor to the home position (row 1, column 1).
  public static let home = "\u{001B}[H"
  /// Clear from the cursor to the end of the screen.
  public static let clearBelow = "\u{001B}[J"
  /// Clear the entire current line.
  public static let clearLine = "\u{001B}[2K"

  /// Enable SGR mouse reporting with button-event tracking.
  ///
  /// Sends `CSI <btn;x;y M/m` sequences. Button 64 = wheel up, 65 = wheel
  /// down. Coordinates are 1-based.
  public static let mouseOn = "\u{001B}[?1006h\u{001B}[?1002h"
  /// Disable SGR mouse reporting.
  public static let mouseOff = "\u{001B}[?1002l\u{001B}[?1006l"

  /// Move the cursor to a 1-based `row`, `col` position.
  public static func move(_ row: Int, _ col: Int) -> String {
    "\u{001B}[\(row);\(col)H"
  }

  /// Set the foreground color using a 24-bit RGB triple.
  public static func fg(_ r: Int, _ g: Int, _ b: Int) -> String {
    "\u{001B}[38;2;\(r);\(g);\(b)m"
  }

  /// Set the background color using a 24-bit RGB triple.
  public static func bg(_ r: Int, _ g: Int, _ b: Int) -> String {
    "\u{001B}[48;2;\(r);\(g);\(b)m"
  }
}
