//
//  BenchConfigTOMLTests.swift
//  SwiftLMRuntimeTests
//
//  Created by Alex Goodkind <alex@goodkind.io> on 2026-04-18.
//  Copyright © 2026
//

import XCTest
@testable import SwiftLMRuntime

final class BenchConfigTOMLTests: XCTestCase {
  // MARK: - Happy path

  func testParsesFullDocument() throws {
    let toml = """
      # comment line
      prompts_dir = "/tmp/prompts"
      results_dir = "/tmp/results"
      repo_path = "/repo"
      run_label = "nightly"
      skip_existing = false
      test_timeout_seconds = 600
      parallelism_per_model = 2

      [[models]]
      id = "qwen3-30b"
      context_size = 131072

      [[models]]
      id = "qwen3-4b"
      max_tokens_override = 4096

      [[variants]]
      name = "review"
      prompt_glob = "review/*.md"
      max_input_bytes = 200_000
      thinking = false

      [[variants]]
      name = "chat"
      prompt_glob = "chat/*.md"
      thinking = true
      """
    let cfg = try loadBenchConfig(fromTOMLText: toml)
    XCTAssertEqual(cfg.promptsDir, "/tmp/prompts")
    XCTAssertEqual(cfg.resultsDir, "/tmp/results")
    XCTAssertEqual(cfg.repoPath, "/repo")
    XCTAssertEqual(cfg.runLabel, "nightly")
    XCTAssertFalse(cfg.skipExisting)
    XCTAssertEqual(cfg.testTimeoutSeconds, 600)
    XCTAssertEqual(cfg.parallelismPerModel, 2)

    XCTAssertEqual(cfg.models.count, 2)
    XCTAssertEqual(cfg.models[0].id, "qwen3-30b")
    XCTAssertEqual(cfg.models[0].contextSize, 131_072)
    XCTAssertEqual(cfg.models[1].id, "qwen3-4b")
    XCTAssertEqual(cfg.models[1].maxTokensOverride, 4096)

    XCTAssertEqual(cfg.variants.count, 2)
    XCTAssertEqual(cfg.variants[0].name, "review")
    XCTAssertEqual(cfg.variants[0].promptGlob, "review/*.md")
    XCTAssertEqual(cfg.variants[0].maxInputBytes, 200_000)
    XCTAssertFalse(cfg.variants[0].thinking)
    XCTAssertTrue(cfg.variants[1].thinking)
  }

  func testDefaultsAppliedWhenOmitted() throws {
    let toml = """
      prompts_dir = "/p"
      results_dir = "/r"

      [[models]]
      id = "a"

      [[variants]]
      name = "v"
      prompt_glob = "*"
      """
    let cfg = try loadBenchConfig(fromTOMLText: toml)
    XCTAssertTrue(cfg.skipExisting)          // default true
    XCTAssertEqual(cfg.testTimeoutSeconds, 900)  // default 900
    XCTAssertEqual(cfg.parallelismPerModel, 1)   // default 1
    XCTAssertEqual(cfg.variants[0].maxInputBytes, 300_000) // default
    XCTAssertEqual(cfg.variants[0].maxTokens, 8192)        // default
  }

  // MARK: - Error cases

  func testMissingPromptsDirThrows() {
    let toml = """
      results_dir = "/r"

      [[models]]
      id = "a"

      [[variants]]
      name = "v"
      prompt_glob = "*"
      """
    XCTAssertThrowsError(try loadBenchConfig(fromTOMLText: toml)) { err in
      guard case BenchConfigTOMLError.typeMismatch(let k, _, let got) = err else {
        return XCTFail("expected typeMismatch, got \(err)")
      }
      XCTAssertEqual(k, "prompts_dir")
      XCTAssertEqual(got, "missing")
    }
  }

  func testEmptyModelsThrows() {
    let toml = """
      prompts_dir = "/p"
      results_dir = "/r"

      [[variants]]
      name = "v"
      prompt_glob = "*"
      """
    XCTAssertThrowsError(try loadBenchConfig(fromTOMLText: toml)) { err in
      XCTAssertEqual(err as? BenchConfigTOMLError, BenchConfigTOMLError.emptyModels)
    }
  }

  func testSingleBracketTablesRejected() {
    let toml = """
      prompts_dir = "/p"
      results_dir = "/r"

      [extra]
      foo = 1
      """
    XCTAssertThrowsError(try loadBenchConfig(fromTOMLText: toml))
  }

  func testDuplicateKeyRejected() {
    let toml = """
      prompts_dir = "/a"
      prompts_dir = "/b"
      results_dir = "/r"

      [[models]]
      id = "x"

      [[variants]]
      name = "v"
      prompt_glob = "*"
      """
    XCTAssertThrowsError(try loadBenchConfig(fromTOMLText: toml)) { err in
      guard case BenchConfigTOMLError.duplicateKey = err else {
        return XCTFail("expected duplicateKey, got \(err)")
      }
    }
  }

  // MARK: - Value coverage

  func testCommentsStripped() throws {
    let toml = """
      prompts_dir = "/p"  # trailing
      # leading comment
      results_dir = "/r"

      [[models]]
      id = "a"  # ok

      [[variants]]
      name = "v"
      prompt_glob = "*"
      """
    let cfg = try loadBenchConfig(fromTOMLText: toml)
    XCTAssertEqual(cfg.promptsDir, "/p")
  }

  func testUnderscoreNumericSeparators() throws {
    let toml = """
      prompts_dir = "/p"
      results_dir = "/r"
      test_timeout_seconds = 1_800

      [[models]]
      id = "a"
      context_size = 262_144

      [[variants]]
      name = "v"
      prompt_glob = "*"
      """
    let cfg = try loadBenchConfig(fromTOMLText: toml)
    XCTAssertEqual(cfg.testTimeoutSeconds, 1800)
    XCTAssertEqual(cfg.models[0].contextSize, 262_144)
  }

  func testEscapesInStrings() throws {
    let toml = """
      prompts_dir = "/a\\nb"
      results_dir = "/r"

      [[models]]
      id = "a"

      [[variants]]
      name = "v"
      prompt_glob = "foo\\\"bar"
      """
    let cfg = try loadBenchConfig(fromTOMLText: toml)
    XCTAssertEqual(cfg.promptsDir, "/a\nb")
    XCTAssertEqual(cfg.variants[0].promptGlob, "foo\"bar")
  }
}
