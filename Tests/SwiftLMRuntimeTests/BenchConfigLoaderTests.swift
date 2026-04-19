//
//  BenchConfigLoaderTests.swift
//  SwiftLMRuntimeTests
//
//  Created by Alex Goodkind <alex@goodkind.io> on 2026-04-18.
//  Copyright © 2026
//

import XCTest
@testable import SwiftLMRuntime

final class BenchConfigLoaderTests: XCTestCase {
  func testLoadsMinimalConfig() throws {
    let json = """
    {
      "prompts_dir": "/tmp/p",
      "results_dir": "/tmp/r",
      "models": [{"id": "mlx-community/Qwen3-Coder-30B-A3B"}],
      "variants": [{"name": "review", "prompt_glob": "review-*.txt"}]
    }
    """
    let cfg = try loadBenchConfig(fromJSON: json.data(using: .utf8)!)
    XCTAssertEqual(cfg.promptsDir, "/tmp/p")
    XCTAssertEqual(cfg.resultsDir, "/tmp/r")
    XCTAssertEqual(cfg.models.count, 1)
    XCTAssertEqual(cfg.variants.count, 1)
    XCTAssertEqual(cfg.variants.first?.maxInputBytes, 300_000)  // default
    XCTAssertTrue(cfg.skipExisting)  // default
  }

  func testRespectsAllOverrides() throws {
    let json = """
    {
      "prompts_dir": "/p",
      "results_dir": "/r",
      "repo_path": "/code",
      "run_label": "tonight",
      "skip_existing": false,
      "test_timeout_seconds": 120,
      "parallelism_per_model": 4,
      "models": [
        {
          "id": "x",
          "context_size": 131072,
          "max_tokens_override": 4096,
          "max_input_bytes_override": 100000
        }
      ],
      "variants": [
        {
          "name": "think",
          "prompt_glob": "*.txt",
          "max_input_bytes": 50000,
          "max_tokens": 16384,
          "thinking": true
        }
      ]
    }
    """
    let cfg = try loadBenchConfig(fromJSON: json.data(using: .utf8)!)
    XCTAssertEqual(cfg.runLabel, "tonight")
    XCTAssertFalse(cfg.skipExisting)
    XCTAssertEqual(cfg.testTimeoutSeconds, 120)
    XCTAssertEqual(cfg.parallelismPerModel, 4)
    XCTAssertEqual(cfg.models[0].contextSize, 131072)
    XCTAssertEqual(cfg.models[0].maxTokensOverride, 4096)
    XCTAssertEqual(cfg.models[0].maxInputBytesOverride, 100000)
    XCTAssertEqual(cfg.variants[0].maxInputBytes, 50000)
    XCTAssertEqual(cfg.variants[0].maxTokens, 16384)
    XCTAssertTrue(cfg.variants[0].thinking)
  }

  func testRejectsEmptyModels() {
    let json = """
    {"prompts_dir": "/p", "results_dir": "/r", "models": [], "variants": [{"name": "v", "prompt_glob": "*"}]}
    """
    XCTAssertThrowsError(try loadBenchConfig(fromJSON: json.data(using: .utf8)!)) { err in
      XCTAssertEqual(err as? BenchConfigLoadError, .emptyModels)
    }
  }

  func testRejectsEmptyVariants() {
    let json = """
    {"prompts_dir": "/p", "results_dir": "/r", "models": [{"id": "m"}], "variants": []}
    """
    XCTAssertThrowsError(try loadBenchConfig(fromJSON: json.data(using: .utf8)!)) { err in
      XCTAssertEqual(err as? BenchConfigLoadError, .emptyVariants)
    }
  }

  func testMissingRequiredFieldIsInvalidJSON() {
    let json = """
    {"prompts_dir": "/p", "models": [{"id": "m"}], "variants": [{"name": "v", "prompt_glob": "*"}]}
    """
    XCTAssertThrowsError(try loadBenchConfig(fromJSON: json.data(using: .utf8)!)) { err in
      if case .invalidJSON = (err as? BenchConfigLoadError) {} else {
        XCTFail("expected invalidJSON, got \(err)")
      }
    }
  }
}
