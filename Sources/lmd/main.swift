//
//  main.swift
//  lmd
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-04-18.
//  Copyright © 2026, all rights reserved.
//
//  `lmd` is the unified foreground CLI for the SwiftLM workstation toolkit.
//  It handles broker commands in process, exposes typed subcommands through
//  Swift ArgumentParser, and keeps `lmd-serve` as the only separate daemon
//  executable.
//

import AppLogger
import ArgumentParser
import Foundation
import LMDBenchTool
import LMDQATool
import LMDTUIHost
import SwiftLMControl
import SwiftLMCore
import SwiftLMRuntime

AppLogger.bootstrap(subsystem: "io.goodkind.lmd")
private let log = AppLogger.logger(category: "DispatcherCLI")

enum PullCommandError: Error {
  case missingDestination
}

private func say(_ string: String = "") {
  FileHandle.standardOutput.write((string + "\n").data(using: .utf8) ?? Data())
}

private func sayErr(_ string: String) {
  FileHandle.standardError.write((string + "\n").data(using: .utf8) ?? Data())
}

private func openBroker() -> BrokerClient {
  do {
    return try BrokerClient()
  } catch {
    log.error("dispatcher.broker_unavailable err=\(String(describing: error), privacy: .public)")
    sayErr("lmd: cannot reach broker over XPC.")
    sayErr("    is the LaunchAgent installed?  see deploy/io.goodkind.lmd.serve.plist.example")
    sayErr("    underlying error: \(error)")
    exit(7)
  }
}

private func statusCommand() {
  let client = openBroker()
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
          mark, model.modelID, model.kind, model.sizeGB, lastUsed, identifierText, contextText,
          ttlText
        )
      )
    }
  case .failure(let error):
    log.error("status.failed err=\(String(describing: error), privacy: .public)")
    sayErr("lmd status: \(error)")
    exit(1)
  }
}

private func loadCommand(request: ModelLoadRequest) {
  let client = openBroker()
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
    exit(1)
  }
}

private func unloadCommand(request: ModelUnloadRequest) {
  let client = openBroker()
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
    exit(1)
  }
}

private func embedCommand(modelId: String, text: String) {
  let client = openBroker()
  defer { client.close() }
  let result = runBlocking { try await client.embed(model: modelId, inputs: [text]) }
  switch result {
  case .success(let vectors):
    guard let first = vectors.first else {
      sayErr("lmd embed: broker returned no vectors")
      exit(1)
    }
    log.notice(
      "embed.completed model=\(modelId, privacy: .public) dims=\(first.count, privacy: .public)")
    say("model: \(modelId)")
    say("dims: \(first.count)")
    let preview = first.prefix(8).map { String(format: "%.4f", $0) }.joined(separator: ", ")
    let suffix = first.count > 8 ? ", ..." : ""
    say("preview: [\(preview)\(suffix)]")
  case .failure(let error):
    log.error(
      "embed.failed model=\(modelId, privacy: .public) err=\(String(describing: error), privacy: .public)"
    )
    sayErr("lmd embed: \(error)")
    exit(1)
  }
}

private func pullCommand(slug: String) {
  let parts = slug.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: true)
  guard parts.count == 2 else {
    sayErr("lmd pull: slug must be `<namespace>/<name>` (got `\(slug)`)")
    log.error("pull.bad_slug slug=\(slug, privacy: .public)")
    exit(2)
  }
  let localDirectory = "\(NSHomeDirectory())/.lmstudio/models/\(slug)"
  log.notice("pull.started slug=\(slug, privacy: .public) dest=\(localDirectory, privacy: .public)")
  say("downloading \(slug) -> \(localDirectory)")

  let client = openBroker()
  defer { client.close() }
  let result = runBlocking {
    var destination: String?
    for try await event in client.pull(slug: slug) {
      switch event {
      case .started(let eventSlug, let eventDestination):
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
      throw PullCommandError.missingDestination
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
    exit(1)
  }
}

private func rmCommand(modelId: String) {
  let catalog = ModelCatalog(roots: ModelCatalog.defaultRoots)
  let match = catalog.allModels().first {
    $0.id == modelId || $0.slug == modelId || $0.displayName == modelId
  }
  guard let descriptor = match else {
    sayErr("lmd rm: no model matching `\(modelId)`. try `lmd ls`.")
    exit(1)
  }
  let sizeGB = Double(descriptor.sizeBytes) / 1_073_741_824
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
    exit(1)
  }
}

private func runBenchFromConfig(configPath: String) async {
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
    exit(2)
  }

  let backend = BrokerBenchBackend(brokerHost: "localhost", brokerPort: 5_400)
  let orchestrator = BenchOrchestrator(
    config: config,
    backend: backend
  ) { event in
    switch event {
    case .runStarted(let total):
      say("running \(total) cells against the broker (HTTP /v1/* surface)")
      log.notice("bench.run_started total=\(total, privacy: .public)")
    case .modelStarting(let model, let pending):
      say("  ▶ \(model.id) (\(pending) tests)")
    case .cellStarted(let cell):
      FileHandle.standardOutput.write(Data("    \(cell.promptFilename) …".utf8))
    case .cellFinished(let cell, let elapsed, let bytes):
      say(" ✓ \(Int(elapsed))s \(bytes)B  [\(cell.variant.name)]")
    case .cellFailed(let cell, let error):
      say(" ✗ \(cell.promptFilename): \(error)")
    case .modelFinished(let model):
      say("  ✓ \(model.id)")
    case .runFinished(let done, let failed):
      say("done. completed=\(done) failed=\(failed)")
      log.notice(
        "bench.run_finished completed=\(done, privacy: .public) failed=\(failed, privacy: .public)"
      )
    }
  }
  _ = await orchestrator.run()
}

private func runBenchFromConfigSync(configPath: String) {
  let group = DispatchGroup()
  group.enter()
  Task {
    await runBenchFromConfig(configPath: configPath)
    group.leave()
  }
  group.wait()
}

private func listCatalog() {
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

  let nameWidth = min(45, (models.map(\.displayName.count).max() ?? 30) + 2)
  let slugWidth = min(50, (models.map { ($0.slug ?? "").count }.max() ?? 30) + 2)
  let kindWidth = 12
  say(
    padRight("NAME", nameWidth)
      + "  " + padRight("SLUG", slugWidth)
      + "  " + padRight("KIND", kindWidth)
      + "  " + padLeft("SIZE", 8)
  )

  for model in models {
    let sizeGB = Double(model.sizeBytes) / 1_073_741_824
    let sizeString = sizeGB >= 0.1 ? String(format: "%.1f GB", sizeGB) : "0"
    say(
      padRight(model.displayName, nameWidth)
        + "  " + padRight(model.slug ?? "-", slugWidth)
        + "  " + padRight(model.kind.rawValue, kindWidth)
        + "  " + padLeft(sizeString, 8)
    )
  }
}

private func resolveSiblingBinary(_ name: String) throws -> URL {
  if let executableURL = Bundle.main.executableURL?.resolvingSymlinksInPath() {
    return executableURL.deletingLastPathComponent().appendingPathComponent(name)
  }
  throw ValidationError("lmd: could not resolve the current executable path")
}

private func runServeBinary() -> Never {
  do {
    let process = Process()
    process.executableURL = try resolveSiblingBinary("lmd-serve")
    process.arguments = []
    try process.run()
    process.waitUntilExit()
    if process.terminationReason == .uncaughtSignal {
      exit(process.terminationStatus)
    }
    exit(process.terminationStatus)
  } catch {
    sayErr("lmd serve: \(error)")
    exit(126)
  }
}

private func remappedArguments() -> [String] {
  let arguments = CommandLine.arguments
  guard let executable = arguments.first else {
    return arguments
  }
  let commandName = URL(fileURLWithPath: executable).lastPathComponent
  switch commandName {
  case "lmd-tui":
    return ["tui"] + Array(arguments.dropFirst())
  case "lmd-bench":
    return ["bench"] + Array(arguments.dropFirst())
  case "lmd-qa":
    return ["qa"] + Array(arguments.dropFirst())
  default:
    return Array(arguments.dropFirst())
  }
}

struct LMDCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "lmd",
    abstract: "Unified CLI for the SwiftLM local-LLM toolkit.",
    version: "0.1.0",
    subcommands: [
      LMDServeCommand.self,
      LMDTUICommand.self,
      LMDBenchCommand.self,
      LMDQACommand.self,
      LMDListCommand.self,
      LMDStatusCommand.self,
      LMDLoadCommand.self,
      LMDUnloadCommand.self,
      LMDEmbedCommand.self,
      LMDPullCommand.self,
      LMDRmCommand.self,
    ]
  )

  mutating func run() throws {
    throw CleanExit.helpRequest()
  }
}

struct LMDServeCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "serve",
    abstract: "Run the broker daemon in the foreground.",
    aliases: ["broker"]
  )

  mutating func run() {
    runServeBinary()
  }
}

struct LMDTUICommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "tui",
    abstract: "Launch the multi-tab TUI.",
    aliases: ["lmd-tui"]
  )

  mutating func run() {
    LMDTUIHost.run()
  }
}

struct LMDBenchCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "bench",
    abstract: "Run the benchmark orchestrator.",
    subcommands: [LMDBenchRunCommand.self],
    aliases: ["benchmark", "lmd-bench"]
  )

  mutating func run() {
    LMDBenchTool.run()
  }
}

struct LMDBenchRunCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "run",
    abstract: "Run a BenchConfig JSON or TOML file through the broker."
  )

  @Argument(help: "Path to the BenchConfig JSON or TOML file.")
  var configPath: String

  mutating func run() {
    runBenchFromConfigSync(configPath: configPath)
  }
}

struct LMDQACommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "qa",
    abstract: "Run the TUI QA harness.",
    aliases: ["lmd-qa"]
  )

  @Argument(help: "Optional QA target. Valid values are `lmd-tui` or `all`.")
  var target: String = "all"

  @Option(
    name: .long, help: "Driver list such as `tmux`, `pty`, `iterm`, or a comma-separated set.")
  var driver: String?

  @Flag(name: .long, help: "Skip coverage enforcement.")
  var noCoverage = false

  @Option(name: .long, help: "Directory for iTerm PNG screenshots.")
  var screenshotDir: String?

  mutating func run() throws {
    var arguments: [String] = []
    if target != "all" {
      arguments.append(target)
    }
    if let driver {
      arguments.append(contentsOf: ["--driver", driver])
    }
    if noCoverage {
      arguments.append("--no-coverage")
    }
    if let screenshotDir {
      arguments.append(contentsOf: ["--screenshot-dir", screenshotDir])
    }
    let exitCode = LMDQATool.run(arguments: arguments)
    guard exitCode == 0 else {
      throw ExitCode(exitCode)
    }
  }
}

struct LMDListCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "ls",
    abstract: "List every model on disk.",
    aliases: ["list", "catalog"]
  )

  mutating func run() {
    listCatalog()
  }
}

struct LMDStatusCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "status",
    abstract: "Show loaded models and memory budget from the running broker."
  )

  mutating func run() {
    statusCommand()
  }
}

struct LMDLoadCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "load",
    abstract: "Preload a model into the broker."
  )

  @Argument(help: "Model identifier to preload.")
  var model: String

  @Option(name: .long, help: "Optional stable identifier to assign to the loaded instance.")
  var identifier: String?

  @Option(name: .long, help: "Optional context length for the loaded model.")
  var contextLength: Int?

  @Option(name: .long, help: "Optional TTL in seconds for idle unload.")
  var ttl: Int?

  @Flag(name: .long, help: "Return only an estimate without loading the model.")
  var estimateOnly = false

  @Flag(name: .long, help: "Include the effective load config in the response.")
  var echoLoadConfig = false

  mutating func run() {
    loadCommand(
      request: ModelLoadRequest(
        model: model,
        identifier: identifier,
        contextLength: contextLength,
        ttlSeconds: ttl,
        estimateOnly: estimateOnly,
        echoLoadConfig: echoLoadConfig
      )
    )
  }
}

struct LMDUnloadCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "unload",
    abstract: "Unload a model from the broker."
  )

  @Argument(help: "Model identifier to unload.")
  var model: String?

  @Option(name: .long, help: "Unload by custom identifier.")
  var identifier: String?

  @Flag(name: .long, help: "Unload every currently loaded model.")
  var all = false

  mutating func run() {
    unloadCommand(request: ModelUnloadRequest(model: model, identifier: identifier, all: all))
  }
}

struct LMDEmbedCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "embed",
    abstract: "POST embeddings to the broker over XPC."
  )

  @Option(name: .shortAndLong, help: "Embedding model identifier.")
  var model: String

  @Option(name: [.customShort("t"), .long], help: "Input text to embed.")
  var input: String

  mutating func run() {
    embedCommand(modelId: model, text: input)
  }
}

struct LMDPullCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "pull",
    abstract: "Download a model from Hugging Face.",
    aliases: ["download"]
  )

  @Argument(help: "Hugging Face slug in `<namespace>/<name>` format.")
  var slug: String

  mutating func run() {
    pullCommand(slug: slug)
  }
}

struct LMDRmCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "rm",
    abstract: "Delete a model from disk after confirmation.",
    aliases: ["delete"]
  )

  @Argument(help: "Model id, slug, or display name.")
  var model: String

  mutating func run() {
    rmCommand(modelId: model)
  }
}

LMDCommand.main(remappedArguments())
