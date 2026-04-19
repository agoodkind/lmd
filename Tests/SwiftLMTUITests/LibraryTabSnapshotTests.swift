//
//  LibraryTabSnapshotTests.swift
//  SwiftLMTUITests
//
//  Created by Alex Goodkind <alex@goodkind.io> on 2026-04-18.
//  Copyright © 2026
//
//  Golden-file snapshot tests for `LibraryTab`. Drives deterministic
//  catalog content into the tab and asserts the rendered grid.
//

import XCTest
@testable import SwiftLMTUI

final class LibraryTabSnapshotTests: XCTestCase {
  func testEmptyCatalog() throws {
    let tab = LibraryTab()
    tab.entries = []
    let buffer = BufferedScreen(rows: 30, cols: 120)
    tab.render(into: buffer, contentRows: 3...28)
    try Snapshot.assertMatches(Snapshot.compose(buffer), name: "library_empty")
  }

  func testThreeModelsNoneLoaded() throws {
    let tab = LibraryTab()
    tab.entries = [
      LibraryEntry(
        id: "mlx-community/Qwen3-Coder-30B-A3B-Instruct-8bit-DWQ-lr9e8",
        displayName: "Qwen3-Coder-30B-A3B-Instruct-8bit-DWQ",
        slug: "mlx-community/Qwen3-Coder-30B",
        sizeGB: 32.4,
        isLoaded: false,
        inFlightRequests: 0
      ),
      LibraryEntry(
        id: "mlx-community/Qwen3.5-4B-MLX-4bit",
        displayName: "Qwen3.5-4B-MLX-4bit",
        slug: "mlx-community/Qwen3.5-4B",
        sizeGB: 2.4,
        isLoaded: false,
        inFlightRequests: 0
      ),
      LibraryEntry(
        id: "microsoft/phi-4-reasoning-plus",
        displayName: "phi-4-reasoning-plus",
        slug: "microsoft/phi-4",
        sizeGB: 8.3,
        isLoaded: false,
        inFlightRequests: 0
      ),
    ]
    let buffer = BufferedScreen(rows: 30, cols: 120)
    tab.render(into: buffer, contentRows: 3...28)
    try Snapshot.assertMatches(
      Snapshot.compose(buffer), name: "library_three_models_none_loaded"
    )
  }

  func testOneLoadedWithInflight() throws {
    let tab = LibraryTab()
    tab.entries = [
      LibraryEntry(
        id: "mlx-community/Qwen3-Coder-30B",
        displayName: "Qwen3-Coder-30B",
        slug: "mlx-community/Qwen3-Coder-30B",
        sizeGB: 32.4,
        isLoaded: true,
        inFlightRequests: 3
      ),
      LibraryEntry(
        id: "mlx-community/Qwen3.5-4B",
        displayName: "Qwen3.5-4B",
        slug: "mlx-community/Qwen3.5-4B",
        sizeGB: 2.4,
        isLoaded: false,
        inFlightRequests: 0
      ),
    ]
    let buffer = BufferedScreen(rows: 30, cols: 120)
    tab.render(into: buffer, contentRows: 3...28)
    try Snapshot.assertMatches(
      Snapshot.compose(buffer), name: "library_one_loaded_inflight"
    )
  }
}
