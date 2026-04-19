//
//  Row.swift
//  SwiftLMTUI
//
//  Created by Alex Goodkind <alex@goodkind.io> on 2026-04-18.
//  Copyright © 2026
//

import Foundation

// MARK: - Row layout

/// Helpers for rendering aligned `label | value | extra` rows.
///
/// Widths are measured by visible character cells (ANSI escapes do not
/// count), so colorized labels still produce a column-aligned output.
public enum Row {
  /// Default label column width. Fits `"P-core max"` plus breathing room.
  public static let defaultLabelWidth = 12
  /// Default value column width.
  public static let defaultValueWidth = 12
  /// Default spacing between any two columns.
  public static let defaultGap = "  "

  /// Render a three-column row: `label | value | extra`.
  ///
  /// Both `label` and `value` are padded out to their target widths. The
  /// `extra` column is appended verbatim so callers can put a progress
  /// bar or any other right-side content without a fixed width.
  public static func three(
    _ label: String,
    _ value: String,
    _ extra: String,
    labelWidth: Int = defaultLabelWidth,
    valueWidth: Int = defaultValueWidth,
    gap: String = defaultGap,
    indent: String = "  "
  ) -> String {
    indent
      + VisibleText.pad(label, labelWidth)
      + gap
      + VisibleText.pad(value, valueWidth)
      + gap
      + extra
  }
}
