//
//  EmbeddingCacheLimitTests.swift
//  SwiftLMEmbedTests
//
//  Created by Alex Goodkind <alex@goodkind.io> on 2026-05-18.
//  Copyright © 2026
//
//  Regression coverage for the embedding-backend MLX cache cap.
//
//  Without a cap, BackendTrace data from the
//  `Settle Duplicate-Load vs MLX-Cache` reproduction showed `mlx_cache`
//  growing from `4 KB` to `40 GB` in 80 s of indexing traffic with one
//  loaded model. With the cap set at backend launch, it holds in a
//  `2.09 GB - 2.18 GB` band. These tests catch accidental edits to the
//  shared constant without requiring a live broker or a Metal-backed
//  test environment.
//

import XCTest

@testable import SwiftLMEmbed

final class EmbeddingCacheLimitTests: XCTestCase {
  /// Sanity-check the value the trace evidence is calibrated against.
  /// If you intentionally retune the cap, update this assertion in the
  /// same change so the rationale stays in sync with the runtime.
  func testCacheLimitBytesContract() {
    let expected = 2 * 1024 * 1024 * 1024
    XCTAssertEqual(NVEmbeddingBackend.cacheLimitBytes, expected)
    XCTAssertEqual(MLXEmbeddingBackend.cacheLimitBytes, expected)
  }
}
