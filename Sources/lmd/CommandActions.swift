//
//  CommandActions.swift
//  lmd
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-06-10.
//  Copyright © 2026, all rights reserved.
//
//  The command bodies behind the `lmd` subcommands. Each action talks to the
//  broker or the on-disk model catalog and reports failure by throwing, so the
//  ArgumentParser entry point owns every process exit.
//

import AppLogger
import ArgumentParser
import Foundation
import SwiftLMControl
import SwiftLMCore
import SwiftLMRuntime

private let log = AppLogger.logger(category: "DispatcherCLI")

// MARK: - Exit codes

// Process exit codes the CLI reports beyond the ArgumentParser defaults. These
// are file-scope constants, not a namespace enum, so this functions-only file
// declares no type and stays exempt from the file_name rule.
private let badInputExitCode: Int32 = 2
private let brokerUnavailableExitCode: Int32 = 7
private let spawnFailureExitCode: Int32 = 126

// MARK: - Display constants

private let embeddingPreviewElementCount = 8
private let pullSlugComponentCount = 2
private let bytesPerGigabyte = 1_073_741_824.0
private let benchBrokerPort = 5_400
private let catalogNameColumnCap = 45
private let catalogSlugColumnCap = 50
private let catalogKindColumnWidth = 12
private let catalogFallbackColumnWidth = 30
private let catalogColumnPadding = 2
private let catalogSizeColumnWidth = 8
private let catalogMinimumDisplayGB = 0.1

// MARK: - Output helpers

private func say(_ string: String = "") {
  FileHandle.standardOutput.write((string + "\n").data(using: .utf8) ?? Data())
}

private func sayErr(_ string: String) {
  FileHandle.standardError.write((string + "\n").data(using: .utf8) ?? Data())
}

// MARK: - Broker connection

private func openBroker() throws -> BrokerClient {
  do {
    return try BrokerClient()
  } catch {
    log.error("dispatcher.broker_unavailable err=\(String(describing: error), privacy: .public)")
    sayErr("lmd: cannot reach broker over XPC.")
    sayErr("    is the LaunchAgent installed?  see deploy/io.goodkind.lmd.serve.plist.example")
    sayErr("    underlying error: \(error)")
    throw ExitCode(brokerUnavailableExitCode)
  }
}

// MARK: - Status

func statusCommand() throws {
  let client = try openBroker()
  defer { client.close() }
  let result = runBlocking { try await client.loaded() }
  switch result {
  case .success(let snapshot):
    say("broker: io.goodkind.lmd.control (XPC)")
    say("allocated: \(String(format: "%.1f", snapshot.allocatedGB)) GB")
    if let availableGB = snapshot.availableGB {
      say("available: \(String(format: "%.1f", availableGB)) GB")
    }
    if let reserveGB = snapshot.reserveGB {
      say("reserve: \(String(format: "%.1f", reserveGB)) GB")
    }
    if snapshot.models.isEmpty {
      say("no models loaded")
      return
    }
    say("loaded:")
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    for model in snapshot.models {
      let mark = model.inFlightRequests > 0 ? "busy" : "idle"
      let lastUsed = formatter.string(from: model.lastUsed)
      let contextText = model.contextLength.map { " context_length=\($0)" } ?? ""
      let ttlText = model.ttlSeconds.map { " ttl=\($0)" } ?? ""
      let identifierText = model.identifier.map { " identifier=\($0)" } ?? ""
      say(
        String(
          format: "  [%@] %@ kind=%@  %.1f GB  last_used=%@%@%@%@",
          mark,
          model.modelID,
          model.kind,
          model.sizeGB,
          lastUsed,
          identifierText,
          contextText,
          ttlText
        )
      )
    }
  case .failure(let error):
    log.error("status.failed err=\(String(describing: error), privacy: .public)")
    sayErr("lmd status: \(error)")
    throw ExitCode.failure
  }
}

// MARK: - Load

func loadCommand(request: ModelLoadRequest) throws {
  let client = try openBroker()
  defer { client.close() }
  let result = runBlocking { try await client.preload(request: request) }
  switch result {
  case .success(let response):
    log.notice(
      "load.completed model=\(request.model, privacy: .public) status=\(response.status, privacy: .public)"
    )
    say("status: \(response.status)")
    say("instance_id: \(response.instanceID)")
    if let canLoad = response.canLoad {
      say("can_load: \(canLoad)")
    }
    if let estimated = response.estimatedTotalMemoryGB {
      say("estimated_total_memory_gb: \(String(format: "%.1f", estimated))")
    }
  case .failure(let error):
    log.error(
      "load.failed model=\(request.model, privacy: .public) err=\(String(describing: error), privacy: .public)"
    )
    sayErr("lmd load: \(error)")
    throw ExitCode.failure
  }
}

// MARK: - Unload

func unloadCommand(request: ModelUnloadRequest) throws {
  let client = try openBroker()
  defer { client.close() }
  let result = runBlocking { try await client.unload(request: request) }
  switch result {
  case .success(let response):
    log.notice(
      "unload.completed models=\(response.modelIDs.joined(separator: ","), privacy: .public)")
    say("status: \(response.status)")
    say("models: \(response.modelIDs.joined(separator: ", "))")
  case .failure(let error):
    log.error("unload.failed err=\(String(describing: error), privacy: .public)")
    sayErr("lmd unload: \(error)")
    throw ExitCode.failure
  }
}

// MARK: - Embed

func embedCommand(modelId: String, text: String) throws {
  let client = try openBroker()
  defer { client.close() }
  let result = runBlocking { try await client.embed(model: modelId, inputs: [text]) }
  switch result {
  case .success(let vectors):
    guard let first = vectors.first else {
      sayErr("lmd embed: broker returned no vectors")
      throw ExitCode.failure
    }
    log.notice(
      "embed.completed model=\(modelId, privacy: .public) dims=\(first.count, privacy: .public)")
    say("model: \(modelId)")
    say("dims: \(first.count)")
    let preview = first.prefix(embeddingPreviewElementCount)
      .map { String(format: "%.4f", $0) }
      .joined(separator: ", ")
    let suffix = first.count > embeddingPreviewElementCount ? ", ..." : ""
    say("preview: [\(preview)\(suffix)]")
  case .failure(let error):
    log.error(
      "embed.failed model=\(modelId, privacy: .public) err=\(String(describing: error), privacy: .public)"
    )
    sayErr("lmd embed: \(error)")
    throw ExitCode.failure
  }
}

// MARK: - Pull

func pullCommand(slug: String) throws {
  let parts = slug.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: true)
  guard parts.count == pullSlugComponentCount else {
    sayErr("lmd pull: slug must be `<namespace>/<name>` (got `\(slug)`)")
    log.error("pull.bad_slug slug=\(slug, privacy: .public)")
    throw ExitCode(badInputExitCode)
  }
  let localDirectory = "\(NSHomeDirectory())/.lmstudio/models/\(slug)"
  log.notice("pull.started slug=\(slug, privacy: .public) dest=\(localDirectory, privacy: .public)")
  say("downloading \(slug) -> \(localDirectory)")

  let client = try openBroker()
  defer { client.close() }
  let result = runBlocking {
    var destination: String?
    for try await event in client.pull(slug: slug) {
      switch event {
      case let .started(eventSlug, eventDestination):
        destination = eventDestination
        log.notice(
          "pull.started slug=\(eventSlug, privacy: .public) destination=\(eventDestination, privacy: .public)"
        )
        say("downloading \(eventSlug) -> \(eventDestination)")
      case .progress(let line):
        log.debug("pull.progress slug=\(slug, privacy: .public) line=\(line, privacy: .public)")
        say(" \(line)")
      }
    }
    guard let destination else {
      throw ValidationError("lmd pull: the broker reported no destination for \(slug)")
    }
    return destination
  }
  switch result {
  case .success(let destination):
    log.notice(
      "pull.completed slug=\(slug, privacy: .public) dest=\(destination, privacy: .public)")
    say("done. \(destination)")
  case .failure(let error):
    log.error(
      "pull.failed slug=\(slug, privacy: .public) err=\(String(describing: error), privacy: .public)"
    )
    sayErr("lmd pull: \(error)")
    throw ExitCode.failure
  }
}

// MARK: - Remove

func rmCommand(modelId: String) throws {
  let catalog = ModelCatalog(roots: ModelCatalog.defaultRoots)
  let match = catalog.allModels().first { descriptor in
    descriptor.id == modelId || descriptor.slug == modelId || descriptor.displayName == modelId
  }
  guard let descriptor = match else {
    sayErr("lmd rm: no model matching `\(modelId)`. try `lmd ls`.")
    throw ExitCode.failure
  }
  let sizeGB = Double(descriptor.sizeBytes) / bytesPerGigabyte
  say(
    "remove \(descriptor.displayName) (\(String(format: "%.1f", sizeGB)) GB) at \(descriptor.path) ? [y/N]"
  )
  guard let line = readLine(), line.lowercased().hasPrefix("y") else {
    say("aborted.")
    return
  }
  do {
    try FileManager.default.removeItem(atPath: descriptor.path)
    log.notice(
      "rm.completed model=\(descriptor.id, privacy: .public) path=\(descriptor.path, privacy: .public)"
    )
    say("removed \(descriptor.path)")
  } catch {
    log.error(
      "rm.failed model=\(descriptor.id, privacy: .public) err=\(String(describing: error), privacy: .public)"
    )
    sayErr("lmd rm: \(error)")
    throw ExitCode.failure
  }
}

// MARK: - Bench

func runBenchFromConfig(configPath: String) async throws {
  let config: BenchConfig
  let useToml = configPath.hasSuffix(".toml") || configPath.hasSuffix(".tml")
  do {
    if useToml {
      config = try loadBenchConfig(fromTOML: configPath)
    } else {
      config = try loadBenchConfig(fromJSON: configPath)
    }
  } catch {
    log.error(
      "bench.config_load_failed path=\(configPath, privacy: .public) err=\(String(describing: error), privacy: .public)"
    )
    sayErr("lmd bench run: failed to load config: \(error)")
    throw ExitCode(badInputExitCode)
  }

  let backend = BrokerBenchBackend(brokerHost: "localhost", brokerPort: benchBrokerPort)
  let orchestrator = BenchOrchestrator(
    config: config,
    backend: backend
  ) { event in
    switch event {
    case .runStarted(let total):
      say("running \(total) cells against the broker (HTTP /v1/* surface)")
      log.notice("bench.run_started total=\(total, privacy: .public)")
    case let .modelStarting(model, pending):
      say("  ▶ \(model.id) (\(pending) tests)")
    case .cellStarted(let cell):
      FileHandle.standardOutput.write(Data("    \(cell.promptFilename) …".utf8))
    case let .cellFinished(cell, elapsed, bytes):
      say(" ✓ \(Int(elapsed))s \(bytes)B  [\(cell.variant.name)]")
    case let .cellFailed(cell, error):
      say(" ✗ \(cell.promptFilename): \(error)")
    case .modelFinished(let model):
      say("  ✓ \(model.id)")
    case let .runFinished(done, failed):
      say("done. completed=\(done) failed=\(failed)")
      log.notice(
        "bench.run_finished completed=\(done, privacy: .public) failed=\(failed, privacy: .public)"
      )
    }
  }
  _ = await orchestrator.run()
}

// MARK: - Catalog listing

func listCatalog() {
  let catalog = ModelCatalog(roots: ModelCatalog.defaultRoots)
  let models = catalog.allModels().filter { $0.sizeBytes > 0 }
  if models.isEmpty {
    say("no models found under \(ModelCatalog.defaultRoots.joined(separator: ", "))")
    return
  }

  func padRight(_ string: String, _ width: Int) -> String {
    if string.count >= width {
      return String(string.prefix(width - 1)) + " "
    }
    return string + String(repeating: " ", count: width - string.count)
  }

  func padLeft(_ string: String, _ width: Int) -> String {
    if string.count >= width {
      return String(string.suffix(width))
    }
    return String(repeating: " ", count: width - string.count) + string
  }

  let longestName = models.map(\.displayName.count).max() ?? catalogFallbackColumnWidth
  let longestSlug = models.map { ($0.slug ?? "").count }.max() ?? catalogFallbackColumnWidth
  let nameWidth = min(catalogNameColumnCap, longestName + catalogColumnPadding)
  let slugWidth = min(catalogSlugColumnCap, longestSlug + catalogColumnPadding)
  say(
    padRight("NAME", nameWidth)
      + "  " + padRight("SLUG", slugWidth)
      + "  " + padRight("KIND", catalogKindColumnWidth)
      + "  " + padLeft("SIZE", catalogSizeColumnWidth)
  )

  for model in models {
    let sizeGB = Double(model.sizeBytes) / bytesPerGigabyte
    let sizeString = sizeGB >= catalogMinimumDisplayGB ? String(format: "%.1f GB", sizeGB) : "0"
    say(
      padRight(model.displayName, nameWidth)
        + "  " + padRight(model.slug ?? "-", slugWidth)
        + "  " + padRight(model.kind.rawValue, catalogKindColumnWidth)
        + "  " + padLeft(sizeString, catalogSizeColumnWidth)
    )
  }
}

// MARK: - Serve passthrough

private func resolveSiblingBinary(_ name: String) throws -> URL {
  if let executableURL = Bundle.main.executableURL?.resolvingSymlinksInPath() {
    return executableURL.deletingLastPathComponent().appendingPathComponent(name)
  }
  throw ValidationError("lmd: could not resolve the current executable path")
}

func runServeBinary() throws {
  let process = Process()
  do {
    process.executableURL = try resolveSiblingBinary("lmd-serve")
    process.arguments = []
    try process.run()
  } catch {
    log.error("serve.spawn_failed err=\(String(describing: error), privacy: .public)")
    sayErr("lmd serve: \(error)")
    throw ExitCode(spawnFailureExitCode)
  }
  process.waitUntilExit()
  throw ExitCode(process.terminationStatus)
}
