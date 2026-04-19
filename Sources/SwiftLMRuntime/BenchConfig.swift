//
//  BenchConfig.swift
//  SwiftLMRuntime
//
//  Created by Alex Goodkind <alex@goodkind.io> on 2026-04-18.
//  Copyright © 2026
//
//  Declarative configuration for a benchmark run. A `BenchConfig` describes
//  everything the orchestrator needs: which models to exercise, which
//  prompts to feed each model, where to write the results, and how to
//  gate resource usage. The initial format is a Swift struct; a TOML
//  decoder is a planned follow-up so users can drop new `.toml` files
//  without recompiling.
//

import AppLogger
import Foundation

private let log = AppLogger.logger(category: "BenchConfig")
import SwiftLMCore

// MARK: - Test variant

/// One named test variant. Each variant is a bucket of prompt files that
/// share the same harness (max input bytes, max output tokens, thinking flag).
///
/// Example: `review` variant uses the `review-*.txt` prompts with strict
/// JSON response-format; `chat` variant uses `chat-*.txt` free-form.
public struct BenchVariant: Sendable, Equatable {
  /// Short identifier used in the result filenames.
  public let name: String
  /// Glob applied under `promptsDir` to pick prompts. `review-*.txt`, etc.
  public let promptGlob: String
  /// Max input bytes passed to the model. Longer inputs get truncated.
  public let maxInputBytes: Int
  /// Max generation tokens the server may emit.
  public let maxTokens: Int
  /// Enable SwiftLM's `--thinking` flag for this variant.
  public let thinking: Bool

  public init(
    name: String,
    promptGlob: String,
    maxInputBytes: Int = 300_000,
    maxTokens: Int = 8192,
    thinking: Bool = false
  ) {
    self.name = name
    self.promptGlob = promptGlob
    self.maxInputBytes = maxInputBytes
    self.maxTokens = maxTokens
    self.thinking = thinking
  }
}

// MARK: - Model spec

/// One model entry in the matrix.
public struct BenchModelSpec: Sendable, Equatable {
  /// Identifier resolvable by `ModelCatalog` (slug, display name, or path).
  public let id: String
  /// Optional sliding-window context size. `nil` uses the model default.
  public let contextSize: Int?
  /// Per-model max token override. `nil` = use the variant's value.
  public let maxTokensOverride: Int?
  /// Per-model input byte override (useful for small-context models).
  public let maxInputBytesOverride: Int?

  public init(
    id: String,
    contextSize: Int? = nil,
    maxTokensOverride: Int? = nil,
    maxInputBytesOverride: Int? = nil
  ) {
    self.id = id
    self.contextSize = contextSize
    self.maxTokensOverride = maxTokensOverride
    self.maxInputBytesOverride = maxInputBytesOverride
  }
}

// MARK: - Bench config

/// Complete declarative definition of a benchmark run.
public struct BenchConfig: Sendable, Equatable {
  /// Directory containing prompt files. Globs from each variant resolve
  /// relative to here.
  public let promptsDir: String
  /// Directory where `<model>/<variant>-<prompt>.json` results go.
  public let resultsDir: String
  /// Optional repo root whose contents get dumped as the user message. When
  /// `nil`, the prompt file itself is treated as the full user message.
  public let repoPath: String?
  /// Which models to run.
  public let models: [BenchModelSpec]
  /// Which variants to run against each model.
  public let variants: [BenchVariant]
  /// Skip tests whose result JSON already exists. Makes restarts idempotent.
  public let skipExisting: Bool
  /// Hard timeout per individual test, in seconds.
  public let testTimeoutSeconds: TimeInterval
  /// Number of simultaneous test requests per model. Usually 1 because the
  /// upstream SwiftLM handles one completion at a time.
  public let parallelismPerModel: Int
  /// Free-form label stored with each result for later aggregation.
  public let runLabel: String

  public init(
    promptsDir: String,
    resultsDir: String,
    repoPath: String? = nil,
    models: [BenchModelSpec],
    variants: [BenchVariant],
    skipExisting: Bool = true,
    testTimeoutSeconds: TimeInterval = 900,
    parallelismPerModel: Int = 1,
    runLabel: String = ""
  ) {
    self.promptsDir = promptsDir
    self.resultsDir = resultsDir
    self.repoPath = repoPath
    self.models = models
    self.variants = variants
    self.skipExisting = skipExisting
    self.testTimeoutSeconds = testTimeoutSeconds
    self.parallelismPerModel = parallelismPerModel
    self.runLabel = runLabel
  }

  // MARK: - Matrix expansion

  /// All (model, variant, promptFile) triples the orchestrator will execute.
  public func expandMatrix(fileManager: FileManager = .default) -> [BenchCell] {
    var cells: [BenchCell] = []
    for model in models {
      for variant in variants {
        let prompts = resolvePrompts(variant: variant, fileManager: fileManager)
        for prompt in prompts {
          cells.append(BenchCell(
            model: model,
            variant: variant,
            promptFilename: prompt
          ))
        }
      }
    }
    return cells
  }

  private func resolvePrompts(variant: BenchVariant, fileManager: FileManager) -> [String] {
    guard let entries = try? fileManager.contentsOfDirectory(atPath: promptsDir) else { return [] }
    // Use a simple glob-to-regex mapping: `*` -> `.*`, `?` -> `.`.
    let pattern = "^" + variant.promptGlob
      .replacingOccurrences(of: ".", with: "\\.")
      .replacingOccurrences(of: "*", with: ".*")
      .replacingOccurrences(of: "?", with: ".") + "$"
    guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
    return entries.filter { name in
      let r = NSRange(name.startIndex..<name.endIndex, in: name)
      return re.firstMatch(in: name, range: r) != nil
    }.sorted()
  }
}

// MARK: - Cell

/// One row of the expanded matrix. Each cell is one HTTP call to the model.
public struct BenchCell: Sendable, Equatable {
  public let model: BenchModelSpec
  public let variant: BenchVariant
  /// Prompt filename, relative to `promptsDir`. Stem (minus `.txt`) becomes
  /// the result filename.
  public let promptFilename: String

  public init(model: BenchModelSpec, variant: BenchVariant, promptFilename: String) {
    self.model = model
    self.variant = variant
    self.promptFilename = promptFilename
  }

  /// Result JSON path for this cell. `<resultsDir>/<modelSlug>/<promptStem>.json`.
  public func resultPath(under resultsDir: String) -> String {
    let modelSlug = BenchCell.sanitize(model.id)
    let stem = (promptFilename as NSString).deletingPathExtension
    return "\(resultsDir)/\(modelSlug)/\(stem).json"
  }

  /// Convert a model id (which may contain `/`) into a filesystem-safe slug.
  public static func sanitize(_ id: String) -> String {
    id.replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: " ", with: "_")
  }
}
