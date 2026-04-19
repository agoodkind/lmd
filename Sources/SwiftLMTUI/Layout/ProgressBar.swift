//
//  ProgressBar.swift
//  SwiftLMTUI
//
//  Created by Alex Goodkind <alex@goodkind.io> on 2026-04-18.
//  Copyright © 2026
//

import Foundation

// MARK: - Progress Bar

/// Inline horizontal progress bar.
public enum ProgressBar {
  /// Render a single-line progress bar.
  ///
  /// - Parameters:
  ///   - percent: Completion percentage, 0 through 100. Clamped.
  ///   - width: Visual width of the bar in character cells.
  ///   - color: ANSI color escape used for the filled portion.
  ///   - emptyColor: ANSI color escape used for the unfilled track.
  /// - Returns: A colored string that is exactly `width` visible cells wide,
  ///   terminated with ``Ansi.reset`` so no attribute bleeds afterward.
  public static func render(
    percent: Double,
    width: Int,
    color: String,
    emptyColor: String = Theme.dim
  ) -> String {
    let clamped = max(0, min(percent, 100))
    let filled = Int((clamped / 100.0) * Double(width))
    let empty = max(0, width - filled)
    let full = String(repeating: "█", count: filled)
    let pad = String(repeating: "·", count: empty)
    return "\(color)\(full)\(emptyColor)\(pad)\(Ansi.reset)"
  }
}
