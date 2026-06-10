//
//  LMDEmbedCommand.swift
//  lmd
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-06-10.
//  Copyright © 2026, all rights reserved.
//

import ArgumentParser

// MARK: - LMDEmbedCommand

struct LMDEmbedCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "embed",
    abstract: "POST embeddings to the broker over XPC."
  )

  @Option(name: .shortAndLong, help: "Embedding model identifier.")
  var model: String

  @Option(name: [.customShort("t"), .long], help: "Input text to embed.")
  var input: String

  mutating func run() throws {
    try embedCommand(modelId: model, text: input)
  }
}
