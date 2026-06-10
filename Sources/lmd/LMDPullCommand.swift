//
//  LMDPullCommand.swift
//  lmd
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-06-10.
//  Copyright © 2026, all rights reserved.
//

import ArgumentParser

// MARK: - LMDPullCommand

struct LMDPullCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "pull",
    abstract: "Download a model from Hugging Face.",
    aliases: ["download"]
  )

  @Argument(help: "Hugging Face slug in `<namespace>/<name>` format.")
  var slug: String

  mutating func run() throws {
    try pullCommand(slug: slug)
  }
}
