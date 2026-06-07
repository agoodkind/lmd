//
//  main.swift
//  lmd-model-host
//
//  Dials the broker's host Mach service, identifies itself with the stdin
//  spawn token, loads its model, and serves requests for its kind. Chat proxies
//  through a child SwiftLM HTTP server owned by this helper. Exits when the
//  broker drops the session or closes stdin.
//

import AppLogger
import Foundation
import SwiftLMHostProtocol
import SwiftLMMetrics
import XPC

// The OTLP export arm is SwiftPM-only. lmd-model-host builds only under SwiftPM,
// so this is always available here; the guard keeps the call site uniform with
// lmd-serve, where the Tuist project compiles it out.
#if canImport(SwiftLMMetricsOTel)
  import SwiftLMMetricsOTel
#endif

AppLogger.bootstrap(subsystem: "io.goodkind.lmd")
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

let hostSourceID = "host:\(args.kind.rawValue):\(args.modelPath)"
// Install the OTLP export arm before bootstrapping the metrics plane, since the
// multiplex is fixed at the first bootstrap. Gated on OTEL_EXPORTER_OTLP_ENDPOINT.
#if canImport(SwiftLMMetricsOTel)
  let otelExport = SwiftLMMetricsOTel.installExportIfEnabled(
    serviceName: "lmd-model-host",
    sourceID: hostSourceID
  )
  SwiftLMMetrics.bootstrap(
    process: "lmd-model-host",
    sourceID: hostSourceID,
    modelID: args.modelPath,
    modelKind: args.kind.rawValue,
    extraFactories: otelExport.factory.map { [$0] } ?? []
  )
#else
  SwiftLMMetrics.bootstrap(
    process: "lmd-model-host",
    sourceID: hostSourceID,
    modelID: args.modelPath,
    modelKind: args.kind.rawValue
  )
#endif

// A box so the session reference is available to the request handler closure.
final class SessionBox: @unchecked Sendable {
  var session: XPCSession?
  func send(_ frame: BackendFrame) { try? session?.send(frame) }

  func sendMetricsSnapshot() {
    do {
      send(.metricsSnapshot(try SwiftLMMetrics.sink.encodedSnapshot()))
    } catch {
      log.error("host.metrics_snapshot_failed err=\(String(describing: error), privacy: .public)")
    }
  }
}
let box = SessionBox()

// The embedding backend, loaded after dial-in. nil for non-embedding kinds,
// which routes their requests to their own host below.
let embeddingHost: EmbeddingHost?
if args.kind == .embedding {
  embeddingHost = EmbeddingHost(modelPath: args.modelPath)
} else {
  embeddingHost = nil
}

// The video backend. nil for non-video kinds. Unlike embedding it loads the VLM
// model lazily on the first request, the same as the broker's former in-process
// backend did, so there is no eager load before `ready`.
let videoHost: VideoHost?
if args.kind == .video {
  videoHost = VideoHost(modelPath: args.modelPath, videoSamplingFPS: args.videoSamplingFPS)
} else {
  videoHost = nil
}

let chatHost: ChatHost?
do {
  if args.kind == .chat {
    chatHost = try ChatHost(
      modelPath: args.modelPath,
      binaryPath: args.swiftLMBinaryPath,
      logPath: args.swiftLMLogPath,
      contextLength: args.contextLength
    )
  } else {
    chatHost = nil
  }
} catch {
  FileHandle.standardError.write(Data("lmd-model-host: chat init failed: \(error)\n".utf8))
  exit(2)
}

let exitAfterShutdown: @Sendable (Int32) -> Void = { code in
  Task {
    await chatHost?.shutdown()
    // Flush the last batch of metrics and spans before the short-lived helper
    // exits, or the collector never sees the final request's telemetry.
    #if canImport(SwiftLMMetricsOTel)
      await otelExport.runner?.shutdownAndFlush()
    #endif
    exit(code)
  }
}

// Dial the broker. The broker is the listener; this child is the client. Each
// request runs on its own Task so the synchronous message handler returns
// immediately and the actor serializes the forward pass.
do {
  box.session = try XPCSession(
    machService: args.hostService,
    incomingMessageHandler: { (inbound: HostInbound) -> (any Encodable)? in
      switch inbound {
      case .control(.applyPowerThrottle(let level)):
        // Only embedding has a GPU cache to shrink; video is unaffected.
        if let embeddingHost {
          Task { await embeddingHost.applyPowerThrottle(level) }
        }
        return nil
      case .request(let request):
        switch request.kind {
        case .embedding:
          guard let embeddingHost else {
            box.send(
              .failed(requestID: request.requestID, message: "embedding host not initialized"))
            return nil
          }
          Task {
            defer { box.sendMetricsSnapshot() }
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
            defer { box.sendMetricsSnapshot() }
            let frames = await videoHost.frames(for: request)
            for frame in frames {
              box.send(frame)
            }
          }
        case .chat:
          guard let chatHost else {
            box.send(.failed(requestID: request.requestID, message: "chat host not initialized"))
            return nil
          }
          Task {
            defer { box.sendMetricsSnapshot() }
            await chatHost.serve(request, send: box.send)
          }
        }
        return nil
      }
    },
    cancellationHandler: { reason in
      log.notice("host.session_canceled reason=\(String(describing: reason), privacy: .public)")
      exitAfterShutdown(0)
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
  if let chatHost {
    do {
      try await chatHost.load()
    } catch {
      FileHandle.standardError.write(Data("lmd-model-host: load failed: \(error)\n".utf8))
      log.error("host.load_failed err=\(String(describing: error), privacy: .public)")
      exitAfterShutdown(1)
      return
    }
  }
  box.send(.ready)
  log.notice("host.ready model=\(args.modelPath, privacy: .public)")
}

// Push memory stats every 2 seconds. Chat reports child SwiftLM RSS and zero
// GPU bytes because MLX allocator stats cannot be read across the process
// boundary. Embedding and video report this helper's in-process MLX stats.
let statsTimer = DispatchSource.makeTimerSource(queue: .global())
statsTimer.schedule(deadline: .now() + 2, repeating: 2)
statsTimer.setEventHandler {
  if let chatHost {
    Task {
      let stats = await chatHost.stats()
      box.send(
        .stats(
          rssBytes: stats.rssBytes,
          gpuActiveBytes: stats.gpuActiveBytes,
          gpuCacheBytes: stats.gpuCacheBytes))
      box.sendMetricsSnapshot()
    }
  } else {
    let stats = HostMemory.currentStats()
    box.send(
      .stats(
        rssBytes: stats.rssBytes,
        gpuActiveBytes: stats.gpuActiveBytes,
        gpuCacheBytes: stats.gpuCacheBytes))
    box.sendMetricsSnapshot()
  }
}
statsTimer.resume()

// Exit when the broker closes stdin (orphan guard) or cancels the session.
DispatchQueue.global().async {
  while readLine(strippingNewline: true) != nil {}
  log.notice("host.stdin_eof exiting")
  exitAfterShutdown(0)
}

dispatchMain()
