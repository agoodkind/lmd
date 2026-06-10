//
//  BenchConfigLoaderTests.swift
//  SwiftLMRuntimeTests
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-04-18.
//  Copyright © 2026, all rights reserved.
//

import Nimble
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
    let cfg = try loadBenchConfig(fromJSON: Data(json.utf8))
    expect(cfg.promptsDir) == "/tmp/p"
    expect(cfg.resultsDir) == "/tmp/r"
    expect(cfg.models.count) == 1
    expect(cfg.variants.count) == 1
    expect(cfg.variants.first?.maxInputBytes) == 300_000  // default
    expect(cfg.skipExisting) == true  // default
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
    let cfg = try loadBenchConfig(fromJSON: Data(json.utf8))
    expect(cfg.runLabel) == "tonight"
    expect(cfg.skipExisting) == false
    expect(cfg.testTimeoutSeconds) == 120
    expect(cfg.parallelismPerModel) == 4
    expect(cfg.models[0].contextSize) == 131_072
    expect(cfg.models[0].maxTokensOverride) == 4_096
    expect(cfg.models[0].maxInputBytesOverride) == 100_000
    expect(cfg.variants[0].maxInputBytes) == 50_000
    expect(cfg.variants[0].maxTokens) == 16_384
    expect(cfg.variants[0].thinking) == true
  }

  func testRejectsEmptyModels() {
    let json = """
      {"prompts_dir": "/p", "results_dir": "/r", "models": [], "variants": [{"name": "v", "prompt_glob": "*"}]}
      """
    expect { try loadBenchConfig(fromJSON: Data(json.utf8)) }
      .to(throwError(BenchConfigLoadError.emptyModels))
  }

  func testRejectsEmptyVariants() {
    let json = """
      {"prompts_dir": "/p", "results_dir": "/r", "models": [{"id": "m"}], "variants": []}
      """
    expect { try loadBenchConfig(fromJSON: Data(json.utf8)) }
      .to(throwError(BenchConfigLoadError.emptyVariants))
  }

  func testMissingRequiredFieldIsInvalidJSON() {
    let json = """
      {"prompts_dir": "/p", "models": [{"id": "m"}], "variants": [{"name": "v", "prompt_glob": "*"}]}
      """
    do {
      _ = try loadBenchConfig(fromJSON: Data(json.utf8))
      fail("expected invalidJSON")
    } catch let error as BenchConfigLoadError {
      if case .invalidJSON = error {
        return
      }
      fail("expected invalidJSON, got \(error)")
    } catch {
      fail("expected invalidJSON, got \(error)")
    }
  }
}
