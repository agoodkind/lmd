//
//  LMDTUICommand.swift
//  lmd
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-06-10.
//  Copyright © 2026, all rights reserved.
//

import AppLogger
import ArgumentParser
import LMDTUIHost

private let log = AppLogger.logger(category: "DispatcherCLI")

// MARK: - LMDTUICommand

struct LMDTUICommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "tui",
    abstract: "Launch the multi-tab TUI.",
    aliases: ["lmd-tui"]
  )

  mutating func run() {
    log.notice("tui.launched")
    LMDTUIHost.run()
  }
}
