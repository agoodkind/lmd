//
//  main.swift
//  lmd-model-host
//
//  Dials the broker's host Mach service, identifies itself with the stdin
//  spawn token, loads its model in-process, and serves requests for its kind.
//  Embedding is served here in-process via SwiftLMEmbed; chat and video land in
//  later phases and fail fast for now. Exits when the broker drops the session
//  or closes stdin.
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

// The embedding backend, loaded after dial-in. nil for non-embedding kinds,
// which routes their requests to their own host below.
let embeddingHost: EmbeddingHost? = args.kind == .embedding
  ? EmbeddingHost(modelPath: args.modelPath) : nil

// The video backend. nil for non-video kinds. Unlike embedding it loads the VLM
// model lazily on the first request, the same as the broker's former in-process
// backend did, so there is no eager load before `ready`.
let videoHost: VideoHost? = args.kind == .video
  ? VideoHost(modelPath: args.modelPath, videoSamplingFPS: args.videoSamplingFPS) : nil

// Dial the broker. The broker is the listener; this child is the client. Each
// request runs on its own Task so the synchronous message handler returns
// immediately and the actor serializes the forward pass.
do {
  box.session = try XPCSession(
    machService: args.hostService,
    incomingMessageHandler: { (request: BackendRequest) -> (any Encodable)? in
      switch request.kind {
      case .embedding:
        guard let embeddingHost else {
          box.send(
            .failed(requestID: request.requestID, message: "embedding host not initialized"))
          return nil
        }
        Task {
          let frames = await embeddingHost.frames(for: request)
          for frame in frames {
            box.send(frame)
          }
        }
      case .video:
        guard let videoHost else {
          box.send(
            .failed(requestID: request.requestID, message: "video host not initialized"))
          return nil
        }
        Task {
          let frames = await videoHost.frames(for: request)
          for frame in frames {
            box.send(frame)
          }
        }
      case .chat:
        box.send(
          .failed(
            requestID: request.requestID,
            message: "\(request.kind.rawValue) serving lands in a later phase"))
      }
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

// Identify immediately so the broker binds this session, then load the model
// and declare readiness. The broker awaits `ready` before sending any request,
// so loading before `ready` is the contract the router relies on.
box.send(.hello(spawnToken: spawnToken))
log.notice(
  "host.dialed model=\(args.modelPath, privacy: .public) kind=\(args.kind.rawValue, privacy: .public)"
)

Task {
  if let embeddingHost {
    do {
      try await embeddingHost.load()
    } catch {
      FileHandle.standardError.write(Data("lmd-model-host: load failed: \(error)\n".utf8))
      log.error("host.load_failed err=\(String(describing: error), privacy: .public)")
      exit(1)
    }
  }
  box.send(.ready)
  log.notice("host.ready model=\(args.modelPath, privacy: .public)")
}

// Push memory stats every 2 seconds: RSS plus MLX GPU active and cache bytes.
let statsTimer = DispatchSource.makeTimerSource(queue: .global())
statsTimer.schedule(deadline: .now() + 2, repeating: 2)
statsTimer.setEventHandler {
  let stats = HostMemory.currentStats()
  box.send(
    .stats(
      rssBytes: stats.rssBytes,
      gpuActiveBytes: stats.gpuActiveBytes,
      gpuCacheBytes: stats.gpuCacheBytes))
}
statsTimer.resume()

// Exit when the broker closes stdin (orphan guard) or cancels the session.
DispatchQueue.global().async {
  while readLine(strippingNewline: true) != nil {}
  log.notice("host.stdin_eof exiting")
  exit(0)
}

dispatchMain()
