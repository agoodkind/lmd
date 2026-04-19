//
//  BenchOrchestrator.swift
//  SwiftLMRuntime
//
//  Created by Alex Goodkind <alex@goodkind.io> on 2026-04-18.
//  Copyright © 2026
//
//  Drives a declarative `BenchConfig` to completion. Knows nothing about
//  specific model ids or subprocess management. It delegates lifecycle
//  to an injected `BenchBackend`. The real executable wires a
//  `SwiftLMBackend.SwiftLMServer`-backed backend in; tests wire a fake one
//  that records calls without spawning a process.
//

import AppLogger
import Foundation

private let log = AppLogger.logger(category: "BenchOrchestrator")

// MARK: - Backend abstraction

/// Minimal surface the orchestrator needs from whatever spawns and talks
/// to a model server.
public protocol BenchBackend: AnyObject, Sendable {
  /// Load the given model at the given context size. Blocks until ready
  /// or throws. Implementations cache the active model so repeated calls
  /// with the same (id, ctx) become no-ops.
  func loadIfNeeded(_ model: BenchModelSpec) throws

  /// Send one chat-completion request. Returns the raw response bytes
  /// (which the orchestrator writes to disk verbatim as the cell result).
  func runChat(
    model: BenchModelSpec,
    variant: BenchVariant,
    systemPrompt: String,
    userContent: String,
    timeout: TimeInterval
  ) async throws -> Data

  /// Shut down any running server associated with the given model.
  func unload(_ model: BenchModelSpec)
}

// MARK: - Progress events

/// Lifecycle events the orchestrator emits so UIs can render progress.
public enum BenchEvent: Sendable {
  case runStarted(totalCells: Int)
  case modelStarting(model: BenchModelSpec, pending: Int)
  case cellStarted(cell: BenchCell)
  case cellFinished(cell: BenchCell, elapsed: TimeInterval, bytes: Int)
  case cellFailed(cell: BenchCell, error: String)
  case modelFinished(model: BenchModelSpec)
  case runFinished(completed: Int, failed: Int)
}

/// Single-method delegate. Kept as a closure so tests and GUIs can just
/// pass a throwaway lambda instead of conforming to a protocol.
public typealias BenchEventHandler = @Sendable (BenchEvent) -> Void

// MARK: - Orchestrator

/// Runs a `BenchConfig` to completion using an injected `BenchBackend`.
///
/// The orchestrator owns the retry / skip / filesystem policy. It does
/// NOT own process management (`BenchBackend` does) or thermal policy
/// (`FanCoordinator` does). Those live in their own layers.
public final class BenchOrchestrator {
  public let config: BenchConfig
  public let backend: BenchBackend
  public let events: BenchEventHandler
  private let fileManager: FileManager
  private let promptsDir: String

  public init(
    config: BenchConfig,
    backend: BenchBackend,
    fileManager: FileManager = .default,
    events: @escaping BenchEventHandler = { _ in }
  ) {
    self.config = config
    self.backend = backend
    self.fileManager = fileManager
    self.events = events
    self.promptsDir = config.promptsDir
  }

  // MARK: - Run

  /// Walk the matrix and execute every pending cell in order. Returns
  /// (completed, failed) counts.
  @discardableResult
  public func run() async -> (completed: Int, failed: Int) {
    var matrix = config.expandMatrix(fileManager: fileManager)
    if config.skipExisting {
      matrix = matrix.filter { !fileManager.fileExists(atPath: $0.resultPath(under: config.resultsDir)) }
    }

    events(.runStarted(totalCells: matrix.count))

    // Group by model so we reload the backend once per model rather than
    // once per cell. Stable by first-seen order.
    let cellsByModel = groupByModel(matrix)
    var completed = 0
    var failed = 0

    for (model, cells) in cellsByModel {
      events(.modelStarting(model: model, pending: cells.count))
      do {
        try backend.loadIfNeeded(model)
      } catch {
        failed += cells.count
        for c in cells {
          events(.cellFailed(cell: c, error: "load failed: \(error)"))
        }
        events(.modelFinished(model: model))
        continue
      }

      for cell in cells {
        guard let systemPrompt = readPrompt(cell.promptFilename) else {
          failed += 1
          events(.cellFailed(cell: cell, error: "missing prompt file"))
          continue
        }
        let userContent = loadUserContent(cell: cell)
        let trimmed = truncateUTF8(userContent, maxBytes: cell.variant.maxInputBytes)

        events(.cellStarted(cell: cell))
        let start = Date()
        do {
          let bytes = try await backend.runChat(
            model: model,
            variant: cell.variant,
            systemPrompt: systemPrompt,
            userContent: trimmed,
            timeout: config.testTimeoutSeconds
          )
          try writeResult(bytes: bytes, cell: cell)
          let elapsed = Date().timeIntervalSince(start)
          completed += 1
          events(.cellFinished(cell: cell, elapsed: elapsed, bytes: bytes.count))
        } catch {
          failed += 1
          events(.cellFailed(cell: cell, error: "\(error)"))
        }
      }
      events(.modelFinished(model: model))
    }
    events(.runFinished(completed: completed, failed: failed))
    return (completed, failed)
  }

  // MARK: - Helpers

  /// Preserve the order in which models first appear while grouping cells.
  func groupByModel(_ cells: [BenchCell]) -> [(BenchModelSpec, [BenchCell])] {
    var seen: [String: Int] = [:]
    var buckets: [(BenchModelSpec, [BenchCell])] = []
    for cell in cells {
      if let idx = seen[cell.model.id] {
        buckets[idx].1.append(cell)
      } else {
        seen[cell.model.id] = buckets.count
        buckets.append((cell.model, [cell]))
      }
    }
    return buckets
  }

  private func readPrompt(_ filename: String) -> String? {
    let path = "\(promptsDir)/\(filename)"
    return try? String(contentsOfFile: path, encoding: .utf8)
  }

  private func loadUserContent(cell: BenchCell) -> String {
    // If a repo path is configured, dump the repo contents; otherwise the
    // prompt file is the entire exchange and there's no user content.
    if let repo = config.repoPath {
      return readRepoDump(repo: repo, maxBytes: cell.variant.maxInputBytes)
    }
    return ""
  }

  private func readRepoDump(repo: String, maxBytes: Int) -> String {
    // Minimal version: concatenate every UTF-8 file under `repo` until we
    // hit the byte budget. The real swiftbench does this with priority
    // extensions; we mirror the general shape here.
    var out = ""
    guard let enumerator = fileManager.enumerator(atPath: repo) else { return "" }
    for case let rel as String in enumerator {
      let full = "\(repo)/\(rel)"
      var isDir: ObjCBool = false
      guard fileManager.fileExists(atPath: full, isDirectory: &isDir), !isDir.boolValue else { continue }
      if rel.contains(".git/") || rel.contains("node_modules/") { continue }
      guard let content = try? String(contentsOfFile: full, encoding: .utf8) else { continue }
      let header = "=== \(rel) ===\n"
      if out.utf8.count + header.utf8.count + content.utf8.count >= maxBytes {
        let remaining = maxBytes - out.utf8.count - header.utf8.count
        if remaining > 64 {
          out += header + String(content.prefix(remaining))
        }
        break
      }
      out += header + content + "\n"
    }
    return out
  }

  private func truncateUTF8(_ s: String, maxBytes: Int) -> String {
    if s.utf8.count <= maxBytes { return s }
    return String(s.prefix(maxBytes))
  }

  private func writeResult(bytes: Data, cell: BenchCell) throws {
    let path = cell.resultPath(under: config.resultsDir)
    let dir = (path as NSString).deletingLastPathComponent
    try? fileManager.createDirectory(atPath: dir, withIntermediateDirectories: true)
    try bytes.write(to: URL(fileURLWithPath: path))
  }
}
