//
//  DevTool+Serve.swift
//  lmd-dev
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-05-10.
//  Copyright © 2026, all rights reserved.
//

import Foundation
import SwiftMkCore

/// How long to wait for launchd to drop a service label after `bootout` before
/// bootstrapping again, in seconds. Shared with the test daemon lifecycle.
let serviceUnloadTimeoutSeconds = 5
/// The interval between launchd service-state polls, in seconds.
private let serviceUnloadPollInterval: TimeInterval = 0.1

// MARK: - Serve lifecycle

extension DevTool {
  func startServe() throws {
    Output.debug("startServe")
    guard fileManager.fileExists(atPath: agentPlistURL().path) else {
      throw ToolError.failure("no agent plist at \(agentPlistURL().path); run 'make install' first")
    }

    let domain = "gui/\(getuid())"
    let serviceTarget = "\(domain)/io.goodkind.lmd.serve"

    // Bootout first if loaded so launchd re-reads the plist and picks up
    // the binary we just copied. The bootout call returns before launchd
    // finishes removing the service label from the domain, so a tight
    // bootstrap right after races and gets EIO. Poll until the label is
    // gone before bootstrapping.
    if isServiceLoaded(serviceTarget) {
      bootoutBestEffort(serviceTarget)
      waitForServiceUnload(serviceTarget, timeoutSeconds: serviceUnloadTimeoutSeconds)
    }

    try runPassthrough("launchctl", ["bootstrap", domain, agentPlistURL().path])
    try writeLine("  bootstrapped io.goodkind.lmd.serve")
  }

  /// Boot out a launchd service, logging rather than throwing because the
  /// caller always re-checks the service state before acting on the result.
  func bootoutBestEffort(_ serviceTarget: String) {
    do {
      try runPassthrough("launchctl", ["bootout", serviceTarget])
    } catch {
      Output.notice("bootout best-effort failed service=\(serviceTarget) error=\(error)")
    }
  }

  /// Probe whether a launchd service is loaded. Uses `launchctl print` and
  /// swallows its stderr so the not-loaded case ("Bad request") does not
  /// leak to the user's terminal.
  func isServiceLoaded(_ serviceTarget: String) -> Bool {
    Output.debug("isServiceLoaded service=\(serviceTarget)")
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
    process.arguments = ["print", serviceTarget]
    let sink = Pipe()
    process.standardOutput = sink
    process.standardError = sink
    do {
      try process.run()
    } catch {
      Output.notice("isServiceLoaded launch failed service=\(serviceTarget) error=\(error)")
      return false
    }
    process.waitUntilExit()
    sink.fileHandleForReading.readDataToEndOfFile()
    return process.terminationStatus == 0
  }

  func waitForServiceUnload(_ serviceTarget: String, timeoutSeconds: Int) {
    let deadline = Date().addingTimeInterval(TimeInterval(timeoutSeconds))
    while Date() < deadline {
      if !isServiceLoaded(serviceTarget) {
        return
      }
      pollDelay(seconds: serviceUnloadPollInterval)
    }
  }

  func stopServe() throws {
    Output.debug("stopServe")
    let service = "gui/\(getuid())/io.goodkind.lmd.serve"
    do {
      try runPassthrough("launchctl", ["bootout", service])
      try writeLine("  booted out io.goodkind.lmd.serve")
    } catch {
      Output.notice("stopServe bootout failed service=\(service) error=\(error)")
      try writeLine("  io.goodkind.lmd.serve was not loaded")
    }
  }

  func restartServe() throws {
    Output.debug("restartServe")
    let service = "gui/\(getuid())/io.goodkind.lmd.serve"
    do {
      try runPassthrough("launchctl", ["kickstart", "-k", service])
      try writeLine("  kickstarted io.goodkind.lmd.serve")
    } catch {
      Output.notice("restartServe kickstart failed service=\(service) error=\(error)")
      try writeLine("  io.goodkind.lmd.serve not registered; run 'make install'")
    }
  }
}
