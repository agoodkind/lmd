//
//  BenchTab.swift
//  SwiftLMTUI
//
//  Created by Alex Goodkind <alex@goodkind.io> on 2026-04-18.
//  Copyright © 2026
//
//  BenchTab renders a live matrix of (model × variant) benchmark cells.
//  Rows = models, cols = variant names, each cell shows a status glyph:
//
//                     review  chat
//      qwen3-30b       ✓       ▶
//      qwen3-4b        ✓       ✓
//      phi-4           ·       ·
//
//  The tab itself is a pure renderer. Populating :attr:`cells`,
//  :attr:`models`, and :attr:`variants` is the host's job; the host
//  polls the results directory (or, once Phase 3D lands, subscribes to
//  the broker's `/swiftlmd/events` SSE stream).
//

import AppLogger
import Foundation

private let log = AppLogger.logger(category: "BenchTab")

// MARK: - Cell status

/// One cell in the matrix.
public enum BenchCellStatus: Sendable, Equatable, Hashable {
  /// No result yet for this cell.
  case idle
  /// Currently executing.
  case running
  /// Succeeded.
  case passed
  /// Failed variant. It carries a short reason (truncated by render).
  case failed(reason: String)
  /// Deliberately skipped (e.g. `skip_existing` matched a prior run).
  case skipped

  fileprivate var glyph: String {
    switch self {
    case .idle: return "·"
    case .running: return "▶"
    case .passed: return "✓"
    case .failed: return "✗"
    case .skipped: return "-"
    }
  }
}

// MARK: - BenchTab

public final class BenchTab: Tab {
  public let label = "bench"
  public let title = "bench"

  /// Models in display order. Rows of the matrix.
  public var models: [String] = []

  /// Variants in display order. Columns of the matrix.
  public var variants: [String] = []

  /// Cell map keyed by `"model::variant"`. Missing keys render as `.idle`.
  public var cells: [String: BenchCellStatus] = [:]

  /// Bench start time, for the elapsed-seconds summary row. `nil` means
  /// "not started yet".
  public var startedAt: Date?

  /// Optional status string shown above the matrix (e.g. "running" /
  /// "paused" / "done"). Empty hides the row.
  public var statusLine: String = ""

  public init() {}

  /// Build a matrix key from a model + variant pair.
  public static func cellKey(model: String, variant: String) -> String {
    "\(model)::\(variant)"
  }

  /// Assign a cell's status. Logs the transition at `.info` so bench
  /// progress shows up in `log stream`.
  public func set(model: String, variant: String, status: BenchCellStatus) {
    let key = Self.cellKey(model: model, variant: variant)
    cells[key] = status
    log.info(
      "bench.cell_status model=\(model, privacy: .public) variant=\(variant, privacy: .public) status=\(status.glyph, privacy: .public)"
    )
  }

  /// Reset the matrix.
  public func clear() {
    log.notice("bench.tab_cleared prior_cells=\(self.cells.count, privacy: .public)")
    cells.removeAll()
    statusLine = ""
    startedAt = nil
  }

  // MARK: - Rendering

  public func render(into buffer: ScreenBuffer, contentRows rows: ClosedRange<Int>) {
    var row = rows.lowerBound
    func write(_ text: String) {
      if row <= rows.upperBound {
        buffer.put(row: row, text)
        row += 1
      }
    }

    // Header.
    let stats = summary()
    let startedSuffix: String
    if let start = startedAt {
      let elapsed = Int(Date().timeIntervalSince(start))
      startedSuffix = " · elapsed \(elapsed)s"
    } else {
      startedSuffix = ""
    }
    let header = "\(Theme.head)BENCH\(Ansi.reset)  "
      + "\(Theme.text)\(stats.done)/\(stats.total)\(Ansi.reset) "
      + "\(Theme.dim)(\(stats.passed) passed · \(stats.failed) failed · \(stats.running) running)\(Ansi.reset)"
      + "\(Theme.dim)\(startedSuffix)\(Ansi.reset)"
    write(header)

    if !statusLine.isEmpty {
      write("\(Theme.dim)status\(Ansi.reset)  \(Theme.text)\(statusLine)\(Ansi.reset)")
    }
    write("")

    if models.isEmpty || variants.isEmpty {
      write("\(Theme.dim)(no bench loaded. run `lmd bench run <file>` to load one)\(Ansi.reset)")
      return
    }

    // Column widths. Model-name column holds the longest model name,
    // capped so giant MLX paths do not push the matrix off-screen. Each
    // variant column is 10 cols wide: enough for the name plus a one-
    // char glyph plus padding.
    let maxModel = min(32, models.map(\.count).max() ?? 8)
    let variantWidth = 12

    var headerLine = "\(Theme.dim)\(rpad("model", maxModel))\(Ansi.reset)"
    for v in variants {
      headerLine += "  \(Theme.dim)\(rpad(v, variantWidth))\(Ansi.reset)"
    }
    write(headerLine)

    for m in models {
      var line = "\(Theme.label)\(rpad(m, maxModel))\(Ansi.reset)"
      for v in variants {
        let s = cells[Self.cellKey(model: m, variant: v)] ?? .idle
        let colored = colorize(s)
        line += "  " + colored + String(repeating: " ", count: max(0, variantWidth - 1))
      }
      write(line)
    }
  }

  public func handle(_ input: TabInput) -> TabAction {
    log.debug("bench.input_handled")
    switch input {
    case .key(.quit): return .quit
    default: return .none
    }
  }

  // MARK: - Summary

  fileprivate struct Summary {
    let total: Int
    let done: Int
    let passed: Int
    let failed: Int
    let running: Int
    let skipped: Int
  }

  fileprivate func summary() -> Summary {
    let total = models.count * variants.count
    var passed = 0, failed = 0, running = 0, skipped = 0
    for v in cells.values {
      switch v {
      case .passed: passed += 1
      case .failed: failed += 1
      case .running: running += 1
      case .skipped: skipped += 1
      case .idle: continue
      }
    }
    return Summary(
      total: total,
      done: passed + failed + skipped,
      passed: passed,
      failed: failed,
      running: running,
      skipped: skipped
    )
  }

  // MARK: - Helpers

  private func colorize(_ status: BenchCellStatus) -> String {
    switch status {
    case .idle: return "\(Theme.dim)\(status.glyph)\(Ansi.reset)"
    case .running: return "\(Theme.accent)\(status.glyph)\(Ansi.reset)"
    case .passed: return "\(Theme.ok)\(status.glyph)\(Ansi.reset)"
    case .failed: return "\(Theme.bad)\(status.glyph)\(Ansi.reset)"
    case .skipped: return "\(Theme.dim)\(status.glyph)\(Ansi.reset)"
    }
  }

  private func rpad(_ s: String, _ width: Int) -> String {
    if s.count >= width { return String(s.prefix(width)) }
    return s + String(repeating: " ", count: width - s.count)
  }
}
