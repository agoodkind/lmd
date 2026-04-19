//
//  Theme.swift
//  SwiftLMTUI
//
//  Created by Alex Goodkind <alex@goodkind.io> on 2026-04-18.
//  Copyright © 2026
//

import Foundation

// MARK: - Theme

/// Color palette for the TUI.
///
/// Properties return complete SGR escape strings ready to concatenate.
/// Use the `reset` escape from ``Ansi`` to close out colored regions.
public enum Theme {
  public static let dim = Ansi.fg(110, 110, 130)
  public static let label = Ansi.fg(170, 170, 200)
  public static let text = Ansi.fg(230, 230, 240)
  public static let ok = Ansi.fg(100, 220, 140)
  public static let warn = Ansi.fg(240, 200, 80)
  public static let bad = Ansi.fg(240, 100, 100)
  public static let accent = Ansi.fg(120, 180, 255)
  public static let head = Ansi.fg(180, 140, 255)

  // MARK: - Status bar backgrounds

  /// Neovim-style dim purple background for the top bar.
  public static let barBg = Ansi.bg(55, 45, 80)
  /// Near-white text used on `barBg`.
  public static let barFg = Ansi.fg(230, 230, 240)
  /// Accent foreground used on `barBg` (lavender).
  public static let barAccent = Ansi.fg(180, 140, 255)
  /// Dim text color used against `barBg`.
  public static let barDim = Ansi.fg(140, 140, 170)

  /// Bottom bar background, slightly darker than `barBg`.
  public static let footBg = Ansi.bg(40, 40, 55)
  /// Foreground text color against `footBg`.
  public static let footFg = Ansi.fg(200, 200, 220)

  // MARK: - Thermal gradient

  /// Pick a color based on a temperature in Celsius.
  public static func tempColor(_ celsius: Double) -> String {
    if celsius >= 90 { return bad }
    if celsius >= 80 { return warn }
    return ok
  }
}
