//
//  LMDRmCommand.swift
//  lmd
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-06-10.
//  Copyright © 2026, all rights reserved.
//

import ArgumentParser

// MARK: - LMDRmCommand

struct LMDRmCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "rm",
    abstract: "Delete a model from disk after confirmation.",
    aliases: ["delete"]
  )

  @Argument(help: "Model id, slug, or display name.")
  var model: String

  mutating func run() throws {
    try rmCommand(modelId: model)
  }
}
