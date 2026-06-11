//
//  LMDBenchCommand.swift
//  lmd
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-06-10.
//  Copyright © 2026, all rights reserved.
//

import AppLogger
import ArgumentParser
import LMDBenchTool

private let log = AppLogger.logger(category: "DispatcherCLI")

// MARK: - LMDBenchCommand

struct LMDBenchCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "bench",
    abstract: "Run the benchmark orchestrator.",
    subcommands: [LMDBenchRunCommand.self, LMDBenchEmbedCommand.self],
    aliases: ["benchmark", "lmd-bench"]
  )

  mutating func run() {
    log.notice("bench.tool_started")
    LMDBenchTool.run()
  }
}
