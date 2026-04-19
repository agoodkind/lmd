//
//  BenchConfigLoader.swift
//  SwiftLMRuntime
//
//  Created by Alex Goodkind <alex@goodkind.io> on 2026-04-18.
//  Copyright © 2026
//
//  JSON-backed loader for `BenchConfig`. Zero dependencies (Foundation
//  only), so a user can drop `configs-battery.json` in the repo and pipe
//  it into `lmd bench run configs-battery.json`. A TOML equivalent is a
//  future add-on; the underlying types are already decoupled.
//

import Foundation

// The `log` handle under category `BenchConfig` lives in BenchConfig.swift.
// Swift's `private` scoping prevents cross-file sharing, so when loader
// events are needed they'll either inline a local handle or refactor.

// MARK: - DTOs

/// Codable mirror of `BenchConfig`. Kept separate so the public
/// configuration type is free of Codable boilerplate.
private struct BenchConfigDTO: Decodable {
  let prompts_dir: String          // swiftlint:disable:this identifier_name
  let results_dir: String          // swiftlint:disable:this identifier_name
  let repo_path: String?           // swiftlint:disable:this identifier_name
  let run_label: String?           // swiftlint:disable:this identifier_name
  let skip_existing: Bool?         // swiftlint:disable:this identifier_name
  let test_timeout_seconds: Double? // swiftlint:disable:this identifier_name
  let parallelism_per_model: Int?   // swiftlint:disable:this identifier_name
  let models: [BenchModelSpecDTO]
  let variants: [BenchVariantDTO]
}

private struct BenchModelSpecDTO: Decodable {
  let id: String
  let context_size: Int?           // swiftlint:disable:this identifier_name
  let max_tokens_override: Int?    // swiftlint:disable:this identifier_name
  let max_input_bytes_override: Int?  // swiftlint:disable:this identifier_name
}

private struct BenchVariantDTO: Decodable {
  let name: String
  let prompt_glob: String          // swiftlint:disable:this identifier_name
  let max_input_bytes: Int?        // swiftlint:disable:this identifier_name
  let max_tokens: Int?             // swiftlint:disable:this identifier_name
  let thinking: Bool?
}

// MARK: - Public loader

public enum BenchConfigLoadError: Error, Equatable {
  case fileNotFound(String)
  case invalidJSON(String)
  case emptyModels
  case emptyVariants
}

/// Load a `BenchConfig` from a JSON file.
public func loadBenchConfig(fromJSON path: String) throws -> BenchConfig {
  guard let data = FileManager.default.contents(atPath: path) else {
    throw BenchConfigLoadError.fileNotFound(path)
  }
  return try loadBenchConfig(fromJSON: data)
}

/// Load a `BenchConfig` from raw JSON bytes. Exposed for tests.
public func loadBenchConfig(fromJSON data: Data) throws -> BenchConfig {
  let dto: BenchConfigDTO
  do {
    dto = try JSONDecoder().decode(BenchConfigDTO.self, from: data)
  } catch {
    throw BenchConfigLoadError.invalidJSON("\(error)")
  }
  if dto.models.isEmpty { throw BenchConfigLoadError.emptyModels }
  if dto.variants.isEmpty { throw BenchConfigLoadError.emptyVariants }
  return BenchConfig(
    promptsDir: dto.prompts_dir,
    resultsDir: dto.results_dir,
    repoPath: dto.repo_path,
    models: dto.models.map { m in
      BenchModelSpec(
        id: m.id,
        contextSize: m.context_size,
        maxTokensOverride: m.max_tokens_override,
        maxInputBytesOverride: m.max_input_bytes_override
      )
    },
    variants: dto.variants.map { v in
      BenchVariant(
        name: v.name,
        promptGlob: v.prompt_glob,
        maxInputBytes: v.max_input_bytes ?? 300_000,
        maxTokens: v.max_tokens ?? 8192,
        thinking: v.thinking ?? false
      )
    },
    skipExisting: dto.skip_existing ?? true,
    testTimeoutSeconds: dto.test_timeout_seconds ?? 900,
    parallelismPerModel: dto.parallelism_per_model ?? 1,
    runLabel: dto.run_label ?? ""
  )
}
