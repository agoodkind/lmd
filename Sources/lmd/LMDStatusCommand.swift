//
//  LMDStatusCommand.swift
//  lmd
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-06-10.
//  Copyright © 2026, all rights reserved.
//

import ArgumentParser

// MARK: - LMDStatusCommand

struct LMDStatusCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "status",
    abstract: "Show loaded models and memory budget from the running broker."
  )

  mutating func run() throws {
    try statusCommand()
  }
}
