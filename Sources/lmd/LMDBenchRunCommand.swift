//
//  LMDBenchRunCommand.swift
//  lmd
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-06-10.
//  Copyright © 2026, all rights reserved.
//

import ArgumentParser

// MARK: - LMDBenchRunCommand

struct LMDBenchRunCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "run",
    abstract: "Run a BenchConfig JSON or TOML file through the broker."
  )

  @Argument(help: "Path to the BenchConfig JSON or TOML file.")
  var configPath: String

  mutating func run() async throws {
    try await runBenchFromConfig(configPath: configPath)
  }
}
