//
//  LMDServeCommand.swift
//  lmd
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-06-10.
//  Copyright © 2026, all rights reserved.
//

import ArgumentParser

// MARK: - LMDServeCommand

struct LMDServeCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "serve",
    abstract: "Run the broker daemon in the foreground.",
    aliases: ["broker"]
  )

  mutating func run() throws {
    try runServeBinary()
  }
}
