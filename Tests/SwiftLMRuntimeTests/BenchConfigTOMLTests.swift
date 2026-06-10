//
//  BenchConfigTOMLTests.swift
//  SwiftLMRuntimeTests
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-04-18.
//  Copyright © 2026, all rights reserved.
//

import Nimble
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
    expect(cfg.promptsDir) == "/tmp/prompts"
    expect(cfg.resultsDir) == "/tmp/results"
    expect(cfg.repoPath) == "/repo"
    expect(cfg.runLabel) == "nightly"
    expect(cfg.skipExisting) == false
    expect(cfg.testTimeoutSeconds) == 600
    expect(cfg.parallelismPerModel) == 2

    expect(cfg.models.count) == 2
    expect(cfg.models[0].id) == "qwen3-30b"
    expect(cfg.models[0].contextSize) == 131_072
    expect(cfg.models[1].id) == "qwen3-4b"
    expect(cfg.models[1].maxTokensOverride) == 4_096

    expect(cfg.variants.count) == 2
    expect(cfg.variants[0].name) == "review"
    expect(cfg.variants[0].promptGlob) == "review/*.md"
    expect(cfg.variants[0].maxInputBytes) == 200_000
    expect(cfg.variants[0].thinking) == false
    expect(cfg.variants[1].thinking) == true
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
    expect(cfg.skipExisting) == true  // default true
    expect(cfg.testTimeoutSeconds) == 900  // default 900
    expect(cfg.parallelismPerModel) == 1  // default 1
    expect(cfg.variants[0].maxInputBytes) == 300_000  // default
    expect(cfg.variants[0].maxTokens) == 8_192  // default
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
    do {
      _ = try loadBenchConfig(fromTOMLText: toml)
      fail("expected typeMismatch")
    } catch BenchConfigTOMLError.typeMismatch(let k, _, let got) {
      expect(k) == "prompts_dir"
      expect(got) == "missing"
    } catch {
      fail("expected typeMismatch, got \(error)")
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
    expect { try loadBenchConfig(fromTOMLText: toml) }
      .to(throwError(BenchConfigTOMLError.emptyModels))
  }

  func testSingleBracketTablesRejected() {
    let toml = """
      prompts_dir = "/p"
      results_dir = "/r"

      [extra]
      foo = 1
      """
    expect { try loadBenchConfig(fromTOMLText: toml) }.to(throwError())
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
    do {
      _ = try loadBenchConfig(fromTOMLText: toml)
      fail("expected duplicateKey")
    } catch let error as BenchConfigTOMLError {
      if case .duplicateKey = error {
        return
      }
      fail("expected duplicateKey, got \(error)")
    } catch {
      fail("expected duplicateKey, got \(error)")
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
    expect(cfg.promptsDir) == "/p"
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
    expect(cfg.testTimeoutSeconds) == 1_800
    expect(cfg.models[0].contextSize) == 262_144
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
    expect(cfg.promptsDir) == "/a\nb"
    expect(cfg.variants[0].promptGlob) == "foo\"bar"
  }
}
