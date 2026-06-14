//
//  LMDLoadCommand.swift
//  lmd
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-06-10.
//  Copyright © 2026, all rights reserved.
//

import ArgumentParser
import SwiftLMControl

// MARK: - LMDLoadCommand

struct LMDLoadCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "load",
    abstract: "Preload a model into the broker."
  )

  @Argument(help: "Model identifier to preload.")
  var model: String

  @Option(name: .long, help: "Optional stable identifier to assign to the loaded instance.")
  var identifier: String?

  @Option(name: .long, help: "Optional context length for the loaded model.")
  var contextLength: Int?

  @Option(name: .long, help: "Optional TTL in seconds for idle unload.")
  var ttl: Int?

  @Option(
    name: .long,
    help: "Optional eviction priority. Higher wins; chat/video default to 100, embedding to 10."
  )
  var priority: Int?

  @Flag(name: .long, help: "Pin the model so it is never auto-unloaded, evicted, or preempted.")
  var pinned = false

  @Flag(name: .long, help: "Return only an estimate without loading the model.")
  var estimateOnly = false

  @Flag(name: .long, help: "Include the effective load config in the response.")
  var echoLoadConfig = false

  mutating func run() throws {
    try loadCommand(
      request: ModelLoadRequest(
        model: model,
        identifier: identifier,
        contextLength: contextLength,
        ttlSeconds: ttl,
        priority: priority,
        pinned: pinned,
        estimateOnly: estimateOnly,
        echoLoadConfig: echoLoadConfig
      )
    )
  }
}
