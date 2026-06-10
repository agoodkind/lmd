//
//  LMDCommand.swift
//  lmd
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-06-10.
//  Copyright © 2026, all rights reserved.
//
//  `lmd` is the unified foreground CLI for the SwiftLM workstation toolkit.
//  It handles broker commands in process, exposes typed subcommands through
//  Swift ArgumentParser, and keeps `lmd-serve` as the only separate daemon
//  executable.
//

import AppLogger
import ArgumentParser
import Foundation

// MARK: - LMDCommand

@main
struct LMDCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "lmd",
    abstract: "Unified CLI for the SwiftLM local-LLM toolkit.",
    version: "0.1.0",
    subcommands: [
      LMDServeCommand.self,
      LMDTUICommand.self,
      LMDBenchCommand.self,
      LMDQACommand.self,
      LMDListCommand.self,
      LMDStatusCommand.self,
      LMDLoadCommand.self,
      LMDUnloadCommand.self,
      LMDEmbedCommand.self,
      LMDPullCommand.self,
      LMDRmCommand.self,
    ]
  )

  static func main() async {
    AppLogger.bootstrap(subsystem: "io.goodkind.lmd")
    await main(remappedArguments())
  }

  mutating func run() throws {
    throw CleanExit.helpRequest()
  }
}

// MARK: - Argument remapping

/// Map alias invocations (`lmd-tui`, `lmd-bench`, `lmd-qa`) onto their
/// subcommands so one binary serves every hardlink name.
private func remappedArguments() -> [String] {
  let arguments = CommandLine.arguments
  guard let executable = arguments.first else {
    return arguments
  }
  let commandName = URL(fileURLWithPath: executable).lastPathComponent
  switch commandName {
  case "lmd-tui":
    return ["tui"] + Array(arguments.dropFirst())
  case "lmd-bench":
    return ["bench"] + Array(arguments.dropFirst())
  case "lmd-qa":
    return ["qa"] + Array(arguments.dropFirst())
  default:
    return Array(arguments.dropFirst())
  }
}
