//
//  BenchTabTests.swift
//  SwiftLMTUITests
//
//  Created by Alex Goodkind <alex@goodkind.io> on 2026-04-18.
//  Copyright © 2026
//

import XCTest
@testable import SwiftLMTUI

final class BenchTabTests: XCTestCase {
  // MARK: - Behavior tests

  func testSetAssignsCell() {
    let t = BenchTab()
    t.models = ["m"]
    t.variants = ["v"]
    t.set(model: "m", variant: "v", status: .passed)
    XCTAssertEqual(t.cells["m::v"], .passed)
  }

  func testClearResetsEverything() {
    let t = BenchTab()
    t.models = ["m"]
    t.variants = ["v"]
    t.startedAt = Date()
    t.statusLine = "running"
    t.set(model: "m", variant: "v", status: .passed)
    t.clear()
    XCTAssertTrue(t.cells.isEmpty)
    XCTAssertEqual(t.statusLine, "")
    XCTAssertNil(t.startedAt)
  }

  func testQuitInputProducesQuitAction() {
    let t = BenchTab()
    let result = t.handle(.key(.quit))
    if case .quit = result { /* ok */ } else { XCTFail("expected .quit, got \(result)") }
  }

  // MARK: - Snapshots

  func testEmptyState() throws {
    let t = BenchTab()
    let buffer = BufferedScreen(rows: 30, cols: 120)
    t.render(into: buffer, contentRows: 3...28)
    try Snapshot.assertMatches(Snapshot.compose(buffer), name: "bench_empty")
  }

  func testMixedStates() throws {
    let t = BenchTab()
    t.statusLine = "running"
    t.models = ["qwen3-30b", "qwen3-4b", "phi-4"]
    t.variants = ["review", "chat"]
    t.set(model: "qwen3-30b", variant: "review", status: .passed)
    t.set(model: "qwen3-30b", variant: "chat", status: .running)
    t.set(model: "qwen3-4b", variant: "review", status: .passed)
    t.set(model: "qwen3-4b", variant: "chat", status: .passed)
    t.set(model: "phi-4", variant: "review", status: .failed(reason: "timeout"))
    // phi-4 / chat stays .idle
    let buffer = BufferedScreen(rows: 30, cols: 120)
    t.render(into: buffer, contentRows: 3...28)
    try Snapshot.assertMatches(Snapshot.compose(buffer), name: "bench_mixed")
  }

  func testAllSkipped() throws {
    let t = BenchTab()
    t.statusLine = "done (nothing to do)"
    t.models = ["m1", "m2"]
    t.variants = ["v1", "v2"]
    for m in t.models {
      for v in t.variants {
        t.set(model: m, variant: v, status: .skipped)
      }
    }
    let buffer = BufferedScreen(rows: 30, cols: 120)
    t.render(into: buffer, contentRows: 3...28)
    try Snapshot.assertMatches(Snapshot.compose(buffer), name: "bench_all_skipped")
  }
}
