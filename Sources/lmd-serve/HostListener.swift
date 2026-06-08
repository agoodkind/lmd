//
//  HostListener.swift
//  lmd-serve
//
//  The broker's second XPC listener, on io.goodkind.lmd.host. Model host
//  children dial in here; the first frame is hello, whose token binds the
//  session to the XPCModelServer the router spawned. Distinct from the control
//  listener (io.goodkind.lmd.control), which serves the CLI and TUI.
//

import AppLogger
import Foundation
import LMDServeSupport
import SwiftLMHostProtocol
import XPC

/// Mach service the model-host children dial in on. `LMD_HOST_SERVICE` overrides
/// it (default `io.goodkind.lmd.host`) so an isolated test LaunchAgent registers
/// a distinct service and never collides with the production daemon. The same
/// value is forwarded to children as `--host-service`, so the listener and the
/// spawned children always agree.
let brokerHostServiceName =
  ProcessInfo.processInfo.environment["LMD_HOST_SERVICE"] ?? "io.goodkind.lmd.host"

/// The launchd LaunchAgent label this broker expects as its process identity.
/// launchd sets `XPC_SERVICE_NAME` to the plist `Label`; both XPC listeners
/// refuse to start unless it matches, since `XPCListener(service:)` traps when
/// the Mach service is not bootstrapped by launchd. `LMD_LAUNCHD_LABEL` overrides
/// the expected label (default `io.goodkind.lmd.serve`) so an isolated test agent
/// labeled `io.goodkind.lmd.serve.test` passes the same guard.
let brokerLaunchdLabel =
  ProcessInfo.processInfo.environment["LMD_LAUNCHD_LABEL"] ?? "io.goodkind.lmd.serve"

private let log = AppLogger.logger(category: "HostListener")

/// Looks up the live XPCModelServer for a model id so a dial-in binds to it.
protocol HostServerRegistry: AnyObject, Sendable {
  func server(forModelID modelID: String) -> XPCModelServer?
}

@discardableResult
func startHostListener(
  pending: PendingSpawns,
  registry: HostServerRegistry
) throws -> XPCListener {
  let env = ProcessInfo.processInfo.environment
  guard env["XPC_SERVICE_NAME"] == brokerLaunchdLabel else {
    throw XPCListenerSkippedError(
      reason: "XPC_SERVICE_NAME=\(env["XPC_SERVICE_NAME"] ?? "<unset>")")
  }
  let listener = try XPCListener(
    service: brokerHostServiceName
  )    { request in
      // Holds the accepted session and the bound server. The session is
      // assigned after `accept` returns, so the message handler closure reads
      // it from here rather than capturing the still-uninitialized binding the
      // same `accept` call produces.
      final class Binder: @unchecked Sendable {
        var session: XPCSession?
        var server: XPCModelServer?
      }
      let binder = Binder()
      let (decision, session) = request.accept(
        incomingMessageHandler: { (frame: BackendFrame) -> (any Encodable)? in
          if case .hello(let token) = frame {
            Task {
              guard let session = binder.session,
                let modelID = await pending.claim(token: token),
                let server = registry.server(forModelID: modelID)
              else {
                log.error("host.hello_unmatched token_present=\(!token.isEmpty, privacy: .public)")
                return
              }
              server.bind(session: session)
              binder.server = server
              log.notice("host.bound model=\(modelID, privacy: .public)")
            }
          } else {
            binder.server?.deliver(frame)
          }
          return nil
        },
        cancellationHandler: { reason in
          log.notice("host.session_canceled reason=\(String(describing: reason), privacy: .public)")
        }
      )
      binder.session = session
      try? session.activate()
      return decision
    }
  log.notice("host.listener_started service=\(brokerHostServiceName, privacy: .public)")
  return listener
}
