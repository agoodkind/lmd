//
//  MaintenanceCatalog.swift
//  lmd-maintenance
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-10-25.
//  Copyright © 2026, all rights reserved.
//

import Foundation
import SwiftMkCore

// MARK: - MaintenanceCatalog

enum MaintenanceCatalog {
  static func run(_ arguments: [String]) throws {
    Output.debug("maintenance.catalog argument_count=\(arguments.count)")
    try requireMaintenanceCondition(
      arguments.count == 1, "Usage: read-patch-versions MANIFEST")
    guard let outputPath = ProcessInfo.processInfo.environment["GITHUB_OUTPUT"],
      !outputPath.isEmpty
    else {
      throw MaintenanceError.failure("Set GITHUB_OUTPUT to the action output file.")
    }
    let data = try Data(contentsOf: URL(fileURLWithPath: arguments[0]))
    let catalog = try JSONDecoder().decode(PatchCatalog.self, from: data)
    try catalog.validate()
    var lines: [String] = []
    for (label, source) in zip(["core", "library", "swiftlm"], catalog.sources) {
      lines.append("\(label)_ref=\(source.forkCommit)")
      Output.info("\(source.repository): \(source.forkCommit)")
    }
    let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: outputPath))
    try handle.seekToEnd()
    try handle.write(contentsOf: Data((lines.joined(separator: "\n") + "\n").utf8))
    try handle.close()
  }
}
