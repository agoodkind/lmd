//
//  ShellExec.swift
//  SwiftLMMonitor
//
//  Created by Alex Goodkind <alex@goodkind.io> on 2026-04-18.
//  Copyright © 2026
//

import AppLogger
import Foundation

private let log = AppLogger.logger(category: "ShellExec")

// MARK: - Shell exec helper

/// Run a command and capture its stdout as a UTF-8 string.
///
/// Internal helper used by sensor wrappers to shell out to `vm_stat`,
/// `pmset`, `sysctl`, and so on. Drops stderr. Returns an empty string
/// on any failure so callers can treat it like a best-effort read.
public func runCaptureStdout(_ path: String, arguments: [String]) -> String {
  let p = Process()
  p.launchPath = path
  p.arguments = arguments
  let pipe = Pipe()
  p.standardOutput = pipe
  p.standardError = FileHandle(forWritingAtPath: "/dev/null")
  do {
    try p.run()
  } catch {
    return ""
  }
  let data = pipe.fileHandleForReading.readDataToEndOfFile()
  p.waitUntilExit()
  return String(data: data, encoding: .utf8) ?? ""
}
