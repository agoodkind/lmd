//
//  LMDUnloadCommand.swift
//  lmd
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-06-10.
//  Copyright © 2026, all rights reserved.
//

import ArgumentParser
import SwiftLMControl

// MARK: - LMDUnloadCommand

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

  mutating func run() throws {
    try unloadCommand(request: ModelUnloadRequest(model: model, identifier: identifier, all: all))
  }
}
