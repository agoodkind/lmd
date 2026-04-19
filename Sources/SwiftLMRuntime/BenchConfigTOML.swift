//
//  BenchConfigTOML.swift
//  SwiftLMRuntime
//
//  Created by Alex Goodkind <alex@goodkind.io> on 2026-04-18.
//  Copyright © 2026
//
//  Minimal TOML decoder scoped to the ``BenchConfig`` schema. Supports
//  exactly what `examples/configs-battery.toml` needs:
//
//      prompts_dir = "/path"
//      results_dir = "/path"
//      skip_existing = true
//      test_timeout_seconds = 900
//
//      [[models]]
//      id = "mlx-community/..."
//      context_size = 131072
//
//      [[variants]]
//      name = "review-general"
//      prompt_glob = "review-general/*.md"
//      max_input_bytes = 300000
//      thinking = false
//
//  Out of scope: inline tables, nested subtables, non-array tables,
//  arrays of values, multiline strings, datetimes, integer literals in
//  bases other than decimal.
//
//  Adding a real TOML dependency (swift-toml) is a reasonable follow-up
//  if the config surface grows. Today's schema stays small enough that
//  a hand-rolled parser is cheaper than a transitive dep.
//

import AppLogger
import Foundation

private let log = AppLogger.logger(category: "BenchConfig")

public enum BenchConfigTOMLError: Error, Equatable, Sendable {
  case fileNotFound(String)
  case invalidSyntax(line: Int, reason: String)
  case duplicateKey(line: Int, key: String)
  case typeMismatch(key: String, expected: String, got: String)
  case emptyModels
  case emptyVariants
}

/// Load a `BenchConfig` from a TOML file.
public func loadBenchConfig(fromTOML path: String) throws -> BenchConfig {
  guard let data = FileManager.default.contents(atPath: path),
        let text = String(data: data, encoding: .utf8)
  else {
    throw BenchConfigTOMLError.fileNotFound(path)
  }
  return try loadBenchConfig(fromTOMLText: text)
}

/// Load a `BenchConfig` from raw TOML text. Exposed for tests.
public func loadBenchConfig(fromTOMLText text: String) throws -> BenchConfig {
  let parsed = try parseToml(text)
  return try buildConfig(from: parsed)
}

// MARK: - Parsed representation

/// In-memory shape produced by :func:`parseToml`. Only the kinds of
/// value we actually accept are modelled.
private enum TOMLValue: Equatable {
  case string(String)
  case int(Int)
  case double(Double)
  case bool(Bool)

  var typeName: String {
    switch self {
    case .string: return "string"
    case .int: return "int"
    case .double: return "double"
    case .bool: return "bool"
    }
  }
}

/// One parsed "section". The root section has empty `key` and holds
/// top-level key/value pairs. Each `[[models]]` / `[[variants]]`
/// occurrence produces an appended element under that key.
private struct TOMLDoc: Equatable {
  var root: [String: TOMLValue] = [:]
  var arrayTables: [String: [[String: TOMLValue]]] = [:]
}

// MARK: - Parser

private func parseToml(_ text: String) throws -> TOMLDoc {
  var doc = TOMLDoc()
  var currentArrayKey: String?
  var currentArrayTable: [String: TOMLValue]?

  func flushCurrentTable() {
    guard let key = currentArrayKey, let tbl = currentArrayTable else { return }
    doc.arrayTables[key, default: []].append(tbl)
    currentArrayKey = nil
    currentArrayTable = nil
  }

  let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
  for (idx, rawLine) in lines.enumerated() {
    let lineNo = idx + 1
    let stripped = trimComment(String(rawLine)).trimmingCharacters(in: .whitespaces)
    if stripped.isEmpty { continue }

    if stripped.hasPrefix("[[") && stripped.hasSuffix("]]") {
      // Array-of-tables header.
      flushCurrentTable()
      let name = stripped.dropFirst(2).dropLast(2).trimmingCharacters(in: .whitespaces)
      guard isIdentifier(name) else {
        throw BenchConfigTOMLError.invalidSyntax(
          line: lineNo,
          reason: "array-of-tables name '\(name)' is not a simple identifier"
        )
      }
      currentArrayKey = name
      currentArrayTable = [:]
      continue
    }

    if stripped.hasPrefix("[") && stripped.hasSuffix("]") {
      throw BenchConfigTOMLError.invalidSyntax(
        line: lineNo,
        reason: "single-bracket tables are not supported; use [[table]] for arrays"
      )
    }

    // key = value
    guard let eq = stripped.firstIndex(of: "=") else {
      throw BenchConfigTOMLError.invalidSyntax(
        line: lineNo,
        reason: "expected 'key = value', got '\(stripped)'"
      )
    }
    let key = String(stripped[..<eq]).trimmingCharacters(in: .whitespaces)
    let valPart = String(stripped[stripped.index(after: eq)...])
      .trimmingCharacters(in: .whitespaces)

    guard isIdentifier(key) else {
      throw BenchConfigTOMLError.invalidSyntax(
        line: lineNo,
        reason: "key '\(key)' is not a simple identifier"
      )
    }

    let value = try parseValue(valPart, line: lineNo)
    if var tbl = currentArrayTable {
      if tbl[key] != nil {
        throw BenchConfigTOMLError.duplicateKey(line: lineNo, key: key)
      }
      tbl[key] = value
      currentArrayTable = tbl
    } else {
      if doc.root[key] != nil {
        throw BenchConfigTOMLError.duplicateKey(line: lineNo, key: key)
      }
      doc.root[key] = value
    }
  }

  flushCurrentTable()
  return doc
}

private func trimComment(_ s: String) -> String {
  // Strip everything after `#` unless it's inside a quoted string.
  var out = ""
  var inQuote = false
  for c in s {
    if c == "\"" { inQuote.toggle() }
    if c == "#" && !inQuote { break }
    out.append(c)
  }
  return out
}

private func isIdentifier(_ s: Substring) -> Bool {
  isIdentifier(String(s))
}

private func isIdentifier(_ s: String) -> Bool {
  guard !s.isEmpty else { return false }
  for c in s {
    if c.isLetter || c.isNumber || c == "_" || c == "-" { continue }
    return false
  }
  return true
}

private func parseValue(_ s: String, line: Int) throws -> TOMLValue {
  if s == "true" { return .bool(true) }
  if s == "false" { return .bool(false) }

  // Quoted string.
  if s.hasPrefix("\"") && s.hasSuffix("\"") && s.count >= 2 {
    let inner = String(s.dropFirst().dropLast())
    return .string(unescape(inner))
  }

  // Numeric.
  let normalized = s.replacingOccurrences(of: "_", with: "")
  if normalized.contains(".") || normalized.contains("e") || normalized.contains("E") {
    if let d = Double(normalized) { return .double(d) }
  } else if let i = Int(normalized) {
    return .int(i)
  }

  throw BenchConfigTOMLError.invalidSyntax(
    line: line,
    reason: "could not parse value '\(s)'"
  )
}

private func unescape(_ s: String) -> String {
  var out = ""
  var iter = s.makeIterator()
  while let c = iter.next() {
    if c == "\\", let next = iter.next() {
      switch next {
      case "n": out.append("\n")
      case "t": out.append("\t")
      case "r": out.append("\r")
      case "\"": out.append("\"")
      case "\\": out.append("\\")
      default:
        out.append("\\")
        out.append(next)
      }
      continue
    }
    out.append(c)
  }
  return out
}

// MARK: - Config construction

private func buildConfig(from doc: TOMLDoc) throws -> BenchConfig {
  let promptsDir = try requireString(doc.root, "prompts_dir")
  let resultsDir = try requireString(doc.root, "results_dir")
  let repoPath = optionalString(doc.root, "repo_path")
  let runLabel = optionalString(doc.root, "run_label") ?? ""
  let skipExisting = optionalBool(doc.root, "skip_existing") ?? true
  let testTimeoutSeconds = optionalDouble(doc.root, "test_timeout_seconds") ?? 900
  let parallelism = optionalInt(doc.root, "parallelism_per_model") ?? 1

  let modelsRaw = doc.arrayTables["models"] ?? []
  let variantsRaw = doc.arrayTables["variants"] ?? []

  if modelsRaw.isEmpty { throw BenchConfigTOMLError.emptyModels }
  if variantsRaw.isEmpty { throw BenchConfigTOMLError.emptyVariants }

  let models: [BenchModelSpec] = try modelsRaw.map { tbl in
    BenchModelSpec(
      id: try requireString(tbl, "id"),
      contextSize: optionalInt(tbl, "context_size"),
      maxTokensOverride: optionalInt(tbl, "max_tokens_override"),
      maxInputBytesOverride: optionalInt(tbl, "max_input_bytes_override")
    )
  }

  let variants: [BenchVariant] = try variantsRaw.map { tbl in
    BenchVariant(
      name: try requireString(tbl, "name"),
      promptGlob: try requireString(tbl, "prompt_glob"),
      maxInputBytes: optionalInt(tbl, "max_input_bytes") ?? 300_000,
      maxTokens: optionalInt(tbl, "max_tokens") ?? 8192,
      thinking: optionalBool(tbl, "thinking") ?? false
    )
  }

  log.info(
    "config.loaded format=toml models=\(models.count, privacy: .public) variants=\(variants.count, privacy: .public)"
  )

  return BenchConfig(
    promptsDir: promptsDir,
    resultsDir: resultsDir,
    repoPath: repoPath,
    models: models,
    variants: variants,
    skipExisting: skipExisting,
    testTimeoutSeconds: testTimeoutSeconds,
    parallelismPerModel: parallelism,
    runLabel: runLabel
  )
}

// MARK: - Table access helpers

private func requireString(_ tbl: [String: TOMLValue], _ key: String) throws -> String {
  guard let v = tbl[key] else {
    throw BenchConfigTOMLError.typeMismatch(key: key, expected: "string", got: "missing")
  }
  if case .string(let s) = v { return s }
  throw BenchConfigTOMLError.typeMismatch(key: key, expected: "string", got: v.typeName)
}

private func optionalString(_ tbl: [String: TOMLValue], _ key: String) -> String? {
  if case .string(let s) = tbl[key] { return s }
  return nil
}

private func optionalInt(_ tbl: [String: TOMLValue], _ key: String) -> Int? {
  switch tbl[key] {
  case .int(let i): return i
  case .double(let d): return Int(d)
  default: return nil
  }
}

private func optionalDouble(_ tbl: [String: TOMLValue], _ key: String) -> Double? {
  switch tbl[key] {
  case .double(let d): return d
  case .int(let i): return Double(i)
  default: return nil
  }
}

private func optionalBool(_ tbl: [String: TOMLValue], _ key: String) -> Bool? {
  if case .bool(let b) = tbl[key] { return b }
  return nil
}
