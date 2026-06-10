//
//  LMDQACommand.swift
//  lmd
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-06-10.
//  Copyright © 2026, all rights reserved.
//

import AppLogger
import ArgumentParser
import LMDQATool

private let log = AppLogger.logger(category: "DispatcherCLI")

// MARK: - LMDQACommand

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
    let qaTarget = target
    log.notice("qa.run_started target=\(qaTarget, privacy: .public)")
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
