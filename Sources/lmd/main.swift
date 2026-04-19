//
//  main.swift
//  lmd
//
//  Created by Alex Goodkind <alex@goodkind.io> on 2026-04-18.
//  Copyright © 2026
//
//  `lmd` is the unified dispatcher for the SwiftLM workstation toolkit.
//  It accepts a subcommand as `argv[1]`, runs the matching inline
//  command (status/load/unload/embed/pull/rm/bench/ls), or execs the
//  matching sibling binary from the same directory (serve/tui/qa).
//
//  All broker-touching commands (status/load/unload/embed/pull) talk to
//  `lmd-serve` over XPC via `SwiftLMControl.BrokerClient`. There is no
//  HTTP or LMD_HOST/LMD_PORT in this file; launchd registers the
//  broker's Mach service via the LaunchAgent plist.
//
//  Sub-binaries produced by this package:
//    lmd-serve   broker + sensor sampler + fan control
//    lmd-tui     interactive multi-tab TUI
//    lmd-bench   benchmark orchestrator (long-running, detached)
//    lmd-qa      test harness (CI / local QA)
//

import AppLogger
import Foundation
import SwiftLMControl
import SwiftLMCore
import SwiftLMRuntime

AppLogger.bootstrap(subsystem: "io.goodkind.lmd")
private let log = AppLogger.logger(category: "DispatcherCLI")

enum PullCommandError: Error {
  case missingDestination
}

// MARK: - User-facing IO helpers
//
// User-facing CLI output. Writes to stdout/stderr without `print`
// machinery so `make log-audit` stays strict. Call-site convention:
// use `say`/`sayErr` for anything the user ran the command to see;
// use `log.<level>(...)` for diagnostics.

private func say(_ s: String = "") {
  FileHandle.standardOutput.write((s + "\n").data(using: .utf8) ?? Data())
}

private func sayErr(_ s: String) {
  FileHandle.standardError.write((s + "\n").data(using: .utf8) ?? Data())
}

// MARK: - Subcommand routing

let subcommandMap: [String: String] = [
  "serve": "lmd-serve",
  "broker": "lmd-serve",
  "lmd-serve": "lmd-serve",

  "tui": "lmd-tui",
  "lmd-tui": "lmd-tui",

  "bench": "lmd-bench",
  "benchmark": "lmd-bench",
  "lmd-bench": "lmd-bench",

  "qa": "lmd-qa",
  "lmd-qa": "lmd-qa",
]

func showUsage() {
  let msg = """
lmd - unified dispatcher for the SwiftLM local-LLM toolkit

USAGE:
  lmd <subcommand> [args...]

SUBCOMMANDS:
  serve             run the broker daemon (broker + sampler + fans)
  tui               launch the multi-tab TUI
  bench             run the benchmark orchestrator
  bench run <cfg>   run a BenchConfig (JSON or TOML) through the broker
  qa                run the TUI QA harness
  ls                list every model on disk (catalog)
  status            show loaded models + memory budget from a running broker
  load <model>      preload a model into the broker
  unload <model>    force-unload a model from the broker
  embed             POST embeddings to the broker (lmd embed -h)
  pull <slug>       download a model from Hugging Face
  rm <model>        delete a model from disk (prompts)

  --help, -h        show this help and exit
  --version, -v     print the version and exit

The broker is reached via XPC (Mach service io.goodkind.lmd.control)
registered by the LaunchAgent plist. There is no host/port to set.
Any argument after a forwarded subcommand is passed verbatim to the
sub-binary (lmd-serve, lmd-tui, lmd-bench, lmd-qa).
"""
  say(msg)
}

let version = "0.1.0"

// MARK: - Dispatch

let argv = CommandLine.arguments
if argv.count < 2 {
  showUsage()
  exit(1)
}

let sub = argv[1]
log.info("dispatcher.invoked sub=\(sub, privacy: .public)")

switch sub {
case "--help", "-h", "help":
  showUsage()
  exit(0)
case "--version", "-v", "version":
  say("lmd \(version)")
  exit(0)
case "ls", "list", "catalog":
  listCatalog()
  exit(0)
case "status":
  statusCommand()
  exit(0)
case "load":
  loadCommand(argv: Array(argv.dropFirst(2)))
  exit(0)
case "unload":
  unloadCommand(argv: Array(argv.dropFirst(2)))
  exit(0)
case "embed":
  embedCommand(argv: Array(argv.dropFirst(2)))
  exit(0)
case "pull", "download":
  pullCommand(argv: Array(argv.dropFirst(2)))
  exit(0)
case "rm", "delete":
  rmCommand(argv: Array(argv.dropFirst(2)))
  exit(0)
case "bench":
  // `lmd bench run <config>` runs an inline BenchConfig. Anything else
  // falls through to execing the classic benchmark binary below.
  let rest = Array(argv.dropFirst(2))
  if rest.first == "run", let configPath = rest.dropFirst().first {
    Task {
      await runBenchFromConfig(configPath: configPath)
      exit(0)
    }
    RunLoop.main.run()
  }
  break
default:
  break
}

// MARK: - Broker client helper

/// Spin up a `BrokerClient` or print a friendly diagnostic and exit.
///
/// XPC session activation is the failure point operators care about:
/// the LaunchAgent plist might be missing, or the daemon's binary
/// might be wrong. Both surface as `BrokerClientError.sessionUnavailable`
/// from `BrokerClient.init`, which we translate into a printable
/// recovery hint.
func openBroker() -> BrokerClient {
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

/// Bridge an async block into the synchronous CLI flow via
/// `SwiftLMControl.runBlocking`, which returns `Result`.
// MARK: - Command handlers

func statusCommand() {
  let client = openBroker()
  defer { client.close() }
  let result = runBlocking { try await client.loaded() }
  switch result {
  case .success(let snap):
    say("broker: io.goodkind.lmd.control (XPC)")
    say("allocated: \(String(format: "%.1f", snap.allocatedGB)) GB")
    if snap.models.isEmpty {
      say("no models loaded")
      return
    }
    say("loaded:")
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    for m in snap.models {
      let mark = m.inFlightRequests > 0 ? "busy" : "idle"
      let last = formatter.string(from: m.lastUsed)
      say(String(
        format: "  [%@] %@ kind=%@  %.1f GB  last_used=%@",
        mark, m.modelID, m.kind, m.sizeGB, last
      ))
    }
  case .failure(let err):
    log.error("status.failed err=\(String(describing: err), privacy: .public)")
    sayErr("lmd status: \(err)")
    exit(1)
  }
}

func loadCommand(argv: [String]) {
  guard let model = argv.first else {
    sayErr("lmd load: missing model id. usage: lmd load <model>")
    exit(2)
  }
  let client = openBroker()
  defer { client.close() }
  let result = runBlocking { try await client.preload(model: model) }
  switch result {
  case .success:
    log.notice("load.completed model=\(model, privacy: .public)")
    say("loaded: \(model)")
  case .failure(let err):
    log.error("load.failed model=\(model, privacy: .public) err=\(String(describing: err), privacy: .public)")
    sayErr("lmd load: \(err)")
    exit(1)
  }
}

func unloadCommand(argv: [String]) {
  guard let model = argv.first else {
    sayErr("lmd unload: missing model id. usage: lmd unload <model>")
    exit(2)
  }
  let client = openBroker()
  defer { client.close() }
  let result = runBlocking { try await client.unload(model: model) }
  switch result {
  case .success:
    log.notice("unload.completed model=\(model, privacy: .public)")
    say("unloaded: \(model)")
  case .failure(let err):
    log.error("unload.failed model=\(model, privacy: .public) err=\(String(describing: err), privacy: .public)")
    sayErr("lmd unload: \(err)")
    exit(1)
  }
}

func embedCommand(argv: [String]) {
  if argv.first == "-h" || argv.first == "--help" {
    say("usage: lmd embed --model <id> --input <text>")
    say("  short flags: -m <id> -t <text>")
    say("  Sends an embed RPC to the broker over XPC.")
    return
  }
  var model: String?
  var input: String?
  var index = 0
  while index < argv.count {
    let token = argv[index]
    if (token == "-m" || token == "--model"), index + 1 < argv.count {
      model = argv[index + 1]
      index += 2
      continue
    }
    if (token == "-t" || token == "--input"), index + 1 < argv.count {
      input = argv[index + 1]
      index += 2
      continue
    }
    index += 1
  }
  guard let modelId = model, let text = input else {
    sayErr("lmd embed: need --model and --input. try lmd embed --help")
    exit(2)
  }
  let client = openBroker()
  defer { client.close() }
  let result = runBlocking { try await client.embed(model: modelId, inputs: [text]) }
  switch result {
  case .success(let vectors):
    guard let first = vectors.first else {
      sayErr("lmd embed: broker returned no vectors")
      exit(1)
    }
    log.notice("embed.completed model=\(modelId, privacy: .public) dims=\(first.count, privacy: .public)")
    say("model: \(modelId)")
    say("dims: \(first.count)")
    let preview = first.prefix(8).map { String(format: "%.4f", $0) }.joined(separator: ", ")
    say("preview: [\(preview)\(first.count > 8 ? ", ..." : "")]")
  case .failure(let err):
    log.error("embed.failed model=\(modelId, privacy: .public) err=\(String(describing: err), privacy: .public)")
    sayErr("lmd embed: \(err)")
    exit(1)
  }
}

// MARK: - pull / rm

/// `lmd pull <hf-slug>` downloads a model into `~/.lmstudio/models/<slug>`.
///
func pullCommand(argv: [String]) {
  guard let slug = argv.first else {
    sayErr("lmd pull: missing HF slug. usage: lmd pull <user/repo>")
    log.error("pull.missing_slug")
    exit(2)
  }
  let parts = slug.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: true)
  guard parts.count == 2 else {
    sayErr("lmd pull: slug must be `<namespace>/<name>` (got `\(slug)`)")
    log.error("pull.bad_slug slug=\(slug, privacy: .public)")
    exit(2)
  }
  let localDir = "\(NSHomeDirectory())/.lmstudio/models/\(slug)"
  log.notice("pull.started slug=\(slug, privacy: .public) dest=\(localDir, privacy: .public)")
  say("downloading \(slug) -> \(localDir)")

  let client = openBroker()
  defer { client.close() }
  let result = runBlocking {
    var destination: String?
    for try await event in client.pull(slug: slug) {
      switch event {
      case .started(let eventSlug, let eventDestination):
        destination = eventDestination
        log.notice("pull.started slug=\(eventSlug, privacy: .public) destination=\(eventDestination, privacy: .public)")
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
  case .success(let dest):
    log.notice("pull.completed slug=\(slug, privacy: .public) dest=\(dest, privacy: .public)")
    say("done. \(dest)")
  case .failure(let err):
    log.error("pull.failed slug=\(slug, privacy: .public) err=\(String(describing: err), privacy: .public)")
    sayErr("lmd pull: \(err)")
    exit(1)
  }
}

/// `lmd rm <model>` deletes a model from disk. Prompts before deleting.
func rmCommand(argv: [String]) {
  guard let id = argv.first else {
    sayErr("lmd rm: missing model id. usage: lmd rm <slug-or-name>")
    exit(2)
  }
  let catalog = ModelCatalog(roots: ModelCatalog.defaultRoots)
  let match = catalog.allModels().first {
    $0.id == id || $0.slug == id || $0.displayName == id
  }
  guard let descriptor = match else {
    sayErr("lmd rm: no model matching `\(id)`. try `lmd ls`.")
    exit(1)
  }
  let gb = Double(descriptor.sizeBytes) / 1_073_741_824
  say("remove \(descriptor.displayName) (\(String(format: "%.1f", gb)) GB) at \(descriptor.path) ? [y/N]")
  guard let line = readLine(), line.lowercased().hasPrefix("y") else {
    say("aborted.")
    return
  }
  do {
    try FileManager.default.removeItem(atPath: descriptor.path)
    log.notice("rm.completed model=\(descriptor.id, privacy: .public) path=\(descriptor.path, privacy: .public)")
    say("removed \(descriptor.path)")
  } catch {
    log.error("rm.failed model=\(descriptor.id, privacy: .public) err=\(String(describing: error), privacy: .public)")
    sayErr("lmd rm: \(error)")
    exit(1)
  }
}

// MARK: - bench run <config>
//
// `lmd bench run <file>` drives a BenchConfig against the broker. The
// BrokerBenchBackend still talks to lmd-serve over HTTP because the
// bench harness was designed against the OpenAI-compatible surface
// and exercises proxying behavior we want to keep verifying. Migrating
// it to XPC is out of scope for the user-facing control plane work.

func runBenchFromConfig(configPath: String) async {
  let config: BenchConfig
  let useToml = configPath.hasSuffix(".toml") || configPath.hasSuffix(".tml")
  do {
    if useToml {
      config = try loadBenchConfig(fromTOML: configPath)
    } else {
      config = try loadBenchConfig(fromJSON: configPath)
    }
  } catch {
    log.error("bench.config_load_failed path=\(configPath, privacy: .public) err=\(String(describing: error), privacy: .public)")
    sayErr("lmd bench run: failed to load config: \(error)")
    exit(2)
  }

  let backend = BrokerBenchBackend(brokerHost: "127.0.0.1", brokerPort: 5400)

  let orch = BenchOrchestrator(
    config: config,
    backend: backend,
    events: { event in
      switch event {
      case .runStarted(let total):
        say("running \(total) cells against the broker (HTTP /v1/* surface)")
        log.notice("bench.run_started total=\(total, privacy: .public)")
      case .modelStarting(let model, let pending):
        say("  ▶ \(model.id) (\(pending) tests)")
      case .cellStarted(let cell):
        FileHandle.standardOutput.write("    \(cell.promptFilename) …".data(using: .utf8)!)
      case .cellFinished(let cell, let elapsed, let bytes):
        say(" ✓ \(Int(elapsed))s \(bytes)B  [\(cell.variant.name)]")
      case .cellFailed(let cell, let error):
        say(" ✗ \(cell.promptFilename): \(error)")
      case .modelFinished(let model):
        say("  ✓ \(model.id)")
      case .runFinished(let done, let failed):
        say("done. completed=\(done) failed=\(failed)")
        log.notice("bench.run_finished completed=\(done, privacy: .public) failed=\(failed, privacy: .public)")
      }
    }
  )
  _ = await orch.run()
}

// MARK: - ls

/// Print the ModelCatalog one row per line. Used by `lmd ls`.
func listCatalog() {
  let catalog = ModelCatalog(roots: ModelCatalog.defaultRoots)
  let models = catalog.allModels().filter { $0.sizeBytes > 0 }
  if models.isEmpty {
    say("no models found under \(ModelCatalog.defaultRoots.joined(separator: ", "))")
    return
  }

  func padRight(_ s: String, _ width: Int) -> String {
    if s.count >= width { return String(s.prefix(width - 1)) + " " }
    return s + String(repeating: " ", count: width - s.count)
  }
  func padLeft(_ s: String, _ width: Int) -> String {
    if s.count >= width { return String(s.suffix(width)) }
    return String(repeating: " ", count: width - s.count) + s
  }

  let nameW = min(45, (models.map { $0.displayName.count }.max() ?? 30) + 2)
  let slugW = min(50, (models.map { ($0.slug ?? "").count }.max() ?? 30) + 2)
  let kindW = 12
  say(
    padRight("NAME", nameW) + "  " + padRight("SLUG", slugW) + "  " + padRight("KIND", kindW)
      + "  " + padLeft("SIZE", 8))

  for m in models {
    let gb = Double(m.sizeBytes) / 1_073_741_824
    let sizeStr = gb >= 0.1 ? String(format: "%.1f GB", gb) : "0"
    say(
      padRight(m.displayName, nameW)
        + "  " + padRight(m.slug ?? "-", slugW)
        + "  " + padRight(m.kind.rawValue, kindW)
        + "  " + padLeft(sizeStr, 8))
  }
}

// MARK: - exec passthrough

guard let target = subcommandMap[sub] else {
  sayErr("lmd: unknown subcommand `\(sub)`")
  showUsage()
  exit(1)
}

let selfPath = argv[0]
let siblingDir = (selfPath as NSString).deletingLastPathComponent
let targetPath = "\(siblingDir)/\(target)"

guard FileManager.default.isExecutableFile(atPath: targetPath) else {
  sayErr("lmd: target binary not executable at \(targetPath)")
  exit(127)
}

let forwardArgs = Array(argv.dropFirst(2))
let childArgv: [String] = [target] + forwardArgs

// execv replaces our process image with the target binary; safer than
// spawning a child because the caller's tty, signals, and exit code
// pass through unchanged.
let cargs: [UnsafeMutablePointer<CChar>?] = childArgv.map { strdup($0) } + [nil]
defer { for p in cargs where p != nil { free(p) } }
let cpath = strdup(targetPath)
defer { if cpath != nil { free(cpath) } }

let rc = execv(cpath, cargs)
sayErr("lmd: execv `\(targetPath)` failed (rc=\(rc), errno=\(errno))")
exit(126)
