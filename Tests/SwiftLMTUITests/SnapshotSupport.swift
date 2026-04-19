//
//  SnapshotSupport.swift
//  SwiftLMTUITests
//
//  Created by Alex Goodkind <alex@goodkind.io> on 2026-04-18.
//  Copyright © 2026
//
//  Shared helpers for TUI snapshot tests. The pattern is:
//
//      let buffer = BufferedScreen(rows: 30, cols: 120)
//      tab.render(into: buffer, contentRows: 3...28)
//      let grid = Snapshot.compose(buffer)
//      try Snapshot.assertMatches(grid, name: "monitor_idle", in: #filePath)
//
//  When the environment variable `SNAPSHOT_UPDATE=1` is set, the assert
//  overwrites the golden file on disk instead of comparing. That's the
//  regeneration workflow. Run `make snapshot-update` after a deliberate
//  rendering change, then review the `.txt` diff on the PR.
//
//  Goldens are stored under `Tests/SwiftLMTUITests/Snapshots/<name>.txt`
//  and contain plain text (ANSI escapes stripped). Reviewers can read
//  them without special tooling.
//

import Foundation
import XCTest
@testable import SwiftLMTUI

enum Snapshot {
  // MARK: - Grid composition

  /// Compose a `BufferedScreen` into a full `rows`-row, `cols`-column text
  /// grid. Rows that were not written are rendered as empty strings. ANSI
  /// escape sequences are stripped so the golden stays human-readable.
  static func compose(_ buffer: BufferedScreen) -> [String] {
    var out: [String] = []
    for row in 1...buffer.rows {
      let raw = buffer.rowsPainted[row] ?? ""
      let visible = stripAnsi(raw)
      out.append(padRight(visible, width: buffer.cols))
    }
    return out
  }

  // MARK: - Assertion

  /// Compare `grid` against the golden file for `name`. When
  /// `SNAPSHOT_UPDATE=1` is set, the golden is overwritten instead.
  static func assertMatches(
    _ grid: [String],
    name: String,
    file: StaticString = #filePath,
    line: UInt = #line
  ) throws {
    let path = goldenURL(for: name, in: String(describing: file))
    let serialized = grid.joined(separator: "\n") + "\n"

    if ProcessInfo.processInfo.environment["SNAPSHOT_UPDATE"] == "1" {
      try FileManager.default.createDirectory(
        at: path.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      try serialized.write(to: path, atomically: true, encoding: .utf8)
      XCTFail(
        "snapshot '\(name)' was written (SNAPSHOT_UPDATE=1). Remove the env var to assert.",
        file: file, line: line
      )
      return
    }

    guard FileManager.default.fileExists(atPath: path.path) else {
      try FileManager.default.createDirectory(
        at: path.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      try serialized.write(to: path, atomically: true, encoding: .utf8)
      XCTFail(
        "snapshot '\(name)' did not exist; wrote initial golden to \(path.path). Re-run to assert.",
        file: file, line: line
      )
      return
    }

    let expected = try String(contentsOf: path, encoding: .utf8)
    if expected == serialized { return }

    let diff = renderDiff(expected: expected, actual: serialized)
    XCTFail(
      """
      snapshot '\(name)' did not match golden at \(path.path).
      To accept the new rendering, re-run with SNAPSHOT_UPDATE=1 and review the PR diff.

      \(diff)
      """,
      file: file, line: line
    )
  }

  // MARK: - Internals

  /// Locate `Tests/SwiftLMTUITests/Snapshots/<name>.txt` relative to the
  /// test file that called us. Walks upward from `filePath` until the
  /// `SwiftLMTUITests` directory is found, then descends into
  /// `Snapshots/`.
  private static func goldenURL(for name: String, in filePath: String) -> URL {
    var dir = URL(fileURLWithPath: filePath).deletingLastPathComponent()
    while dir.path != "/" {
      if dir.lastPathComponent == "SwiftLMTUITests" {
        return dir.appendingPathComponent("Snapshots")
                  .appendingPathComponent("\(name).txt")
      }
      dir = dir.deletingLastPathComponent()
    }
    // Fallback: sibling of the test file.
    return URL(fileURLWithPath: filePath)
      .deletingLastPathComponent()
      .appendingPathComponent("Snapshots")
      .appendingPathComponent("\(name).txt")
  }

  private static func stripAnsi(_ s: String) -> String {
    var out = ""
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
      out.append(ch)
    }
    return out
  }

  private static func padRight(_ s: String, width: Int) -> String {
    if s.count >= width { return String(s.prefix(width)) }
    return s + String(repeating: " ", count: width - s.count)
  }

  private static func renderDiff(expected: String, actual: String) -> String {
    let e = expected.split(separator: "\n", omittingEmptySubsequences: false)
    let a = actual.split(separator: "\n", omittingEmptySubsequences: false)
    var lines: [String] = []
    let count = max(e.count, a.count)
    for i in 0..<count {
      let eRow = i < e.count ? String(e[i]) : ""
      let aRow = i < a.count ? String(a[i]) : ""
      if eRow != aRow {
        lines.append("  row \(String(format: "%2d", i)) expected | \(trim(eRow))")
        lines.append("  row \(String(format: "%2d", i)) actual   | \(trim(aRow))")
        if lines.count > 40 { break }
      }
    }
    if lines.isEmpty { return "(rows identical but length differs)" }
    return lines.joined(separator: "\n")
  }

  private static func trim(_ s: String) -> String {
    var out = s
    while out.last == " " { out.removeLast() }
    return out.isEmpty ? "<blank>" : out
  }
}
