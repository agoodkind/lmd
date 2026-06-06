//
//  main.swift
//  lmd-model-host
//
//  Phase 1 skeleton. Dials the broker's host Mach service, identifies itself
//  with the stdin spawn token, reports readiness and memory, and exits when
//  the broker drops the session or closes stdin. Model loading is Phase 2+.
//

import AppLogger
import Foundation
import SwiftLMHostProtocol
import XPC

private let log = AppLogger.logger(category: "ModelHost")

guard let args = HostArguments.parse(Array(CommandLine.arguments.dropFirst())) else {
  FileHandle.standardError.write(Data("lmd-model-host: bad arguments\n".utf8))
  exit(2)
}

// The spawn token is the first line on stdin, a private parent-to-child pipe.
guard let tokenLine = readLine(strippingNewline: true), !tokenLine.isEmpty else {
  FileHandle.standardError.write(Data("lmd-model-host: missing stdin spawn token\n".utf8))
  exit(2)
}
let spawnToken = tokenLine

// A box so the session reference is available to the request handler closure.
final class SessionBox: @unchecked Sendable {
  var session: XPCSession?
  func send(_ frame: BackendFrame) { try? session?.send(frame) }
}
let box = SessionBox()

// Dial the broker. The broker is the listener; this child is the client.
do {
  box.session = try XPCSession(
    machService: args.hostService,
    incomingMessageHandler: { (request: BackendRequest) -> (any Encodable)? in
      // Phase 1: no model loaded, so every request fails fast. Phase 2 routes
      // by `request.kind` into the loaded MLX model.
      box.send(.failed(requestID: request.requestID, message: "model loading lands in Phase 2"))
      return nil
    },
    cancellationHandler: { reason in
      log.notice("host.session_canceled reason=\(String(describing: reason), privacy: .public)")
      exit(0)
    }
  )
} catch {
  FileHandle.standardError.write(Data("lmd-model-host: dial failed: \(error)\n".utf8))
  exit(1)
}

// Identify, then declare readiness (no model to load in Phase 1).
box.send(.hello(spawnToken: spawnToken))
box.send(.ready)
log.notice(
  "host.ready model=\(args.modelPath, privacy: .public) kind=\(args.kind.rawValue, privacy: .public)"
)

// Push memory stats every 2 seconds.
let statsTimer = DispatchSource.makeTimerSource(queue: .global())
statsTimer.schedule(deadline: .now() + 2, repeating: 2)
statsTimer.setEventHandler {
  let stats = HostMemory.currentStats()
  box.send(.stats(rssBytes: stats.rssBytes, gpuActiveBytes: 0, gpuCacheBytes: 0))
}
statsTimer.resume()

// Exit when the broker closes stdin (orphan guard) or cancels the session.
DispatchQueue.global().async {
  while readLine(strippingNewline: true) != nil {}
  log.notice("host.stdin_eof exiting")
  exit(0)
}

dispatchMain()
