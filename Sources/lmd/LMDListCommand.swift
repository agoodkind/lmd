//
//  LMDListCommand.swift
//  lmd
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-06-10.
//  Copyright © 2026, all rights reserved.
//

import ArgumentParser

// MARK: - LMDListCommand

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
