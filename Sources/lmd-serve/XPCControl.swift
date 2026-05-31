//
//  XPCControl.swift
//  lmd-serve
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-04-19.
//  Copyright © 2026, all rights reserved.
//
//  XPC control surface for the broker.
//
//  Mirrors a subset of the OpenAI/swiftlmd HTTP routes (health, loaded,
//  preload, unload, embed, pull) over a Mach service so first-party
//  Swift clients (`lmd` CLI, `lmd-tui`) talk to the daemon via XPC
//  instead of HTTP loopback. The HTTP server still serves third-party
//  OpenAI-compatible callers; both share a single `BrokerState`.
//
//  Peer authorization: the daemon registers under `gui/$(id -u)` via
//  the LaunchAgent plist, so launchd already restricts connections to
//  the same user session. Cross-uid attempts never reach this listener.
//

import AppLogger
import Foundation
import SwiftLMBackend
import SwiftLMControl
import SwiftLMCore
import SwiftLMRuntime
import SwiftLMTrace
import XPC

private let log = AppLogger.logger(category: "XPCControl")
private let signposter = AppLogger.signposter(category: "Performance")

// MARK: - Listener boot

/// Stand up the XPC control listener and return the listener handle.
///
/// The listener stays retained for the life of the broker; callers
/// store the result so it isn't deallocated. Each accepted session
/// dispatches its requests on a private queue tagged for the client.
/// Indicates the listener was deliberately not started because the
/// process is not running under launchd with the matching MachServices
/// bootstrap. `XPCListener(service:)` traps with an internal
/// `_assertionFailure` (uncatchable, brk 1) when invoked outside that
/// environment, so we have to detect the situation up front. Surface
/// it as a typed error so callers can log a warning and continue with
/// the HTTP surface only.
struct XPCListenerSkippedError: Error, CustomStringConvertible {
  let reason: String
  var description: String { "xpc listener skipped: \(reason)" }
}

@discardableResult
func startXPCControl(state: BrokerState) throws -> XPCListener {
  // launchd sets XPC_SERVICE_NAME to our LaunchAgent label whenever it
  // boots us via the MachServices bootstrap. If that variable is
  // missing (xctest harness, `make run-serve`, manual invocation), the
  // XPCListener registration would assertion-fail inside libxpc, so
  // refuse to call it. Verified against crash reports
  // lmd-serve-2026-04-19-14{2832,2942,3007}.ips, which all faulted in
  // `_assertionFailure` from `startXPCControl` under parentProc=xctest.
  let env = ProcessInfo.processInfo.environment
  let expectedLabel = "io.goodkind.lmd.serve"
  guard env["XPC_SERVICE_NAME"] == expectedLabel else {
    let observed = env["XPC_SERVICE_NAME"] ?? "<unset>"
    log.notice(
      "xpc.listener_skipped reason=not_under_launchd expected=\(expectedLabel, privacy: .public) observed=\(observed, privacy: .public)"
    )
    throw XPCListenerSkippedError(reason: "XPC_SERVICE_NAME=\(observed)")
  }

  let listener = try XPCListener(
    service: brokerXPCServiceName,
    incomingSessionHandler: { request in
      // One queue per client session. Keeps a slow embed call from
      // blocking another client's `health` ping.
      let queue = DispatchQueue(label: "io.goodkind.lmd.control.session")
      let handler = SessionHandler(state: state, queue: queue)
      let (decision, session) = request.accept(
        incomingMessageHandler: { (message: BrokerRequest) -> (any Encodable)? in
          handler.handle(request: message)
        },
        cancellationHandler: { reason in
          handler.handleCancellation(reason: String(describing: reason))
        }
      )
      // Stash the session reference so server-initiated frames (pull
      // events) have somewhere to land. Activated below.
      handler.bind(session: session)
      do {
        try session.activate()
        log.info("xpc.session_accepted")
      } catch {
        log.error("xpc.session_activate_failed err=\(String(describing: error), privacy: .public)")
      }
      return decision
    }
  )
  log.notice("xpc.listener_started service=\(brokerXPCServiceName, privacy: .public)")
  return listener
}

// MARK: - Per-session handler

/// Per-session dispatch. Owns the inbound request decoding, the
/// outbound session handle (for streaming pulls), and a small queue so
/// long-running operations don't starve concurrent clients.
private final class SessionHandler: @unchecked Sendable {
  let state: BrokerState
  let queue: DispatchQueue
  private var session: XPCSession?
  private var eventTask: Task<Void, Never>?

  init(state: BrokerState, queue: DispatchQueue) {
    self.state = state
    self.queue = queue
  }

  func bind(session: XPCSession) {
    queue.sync { self.session = session }
  }

  /// Reply-bearing dispatch. Returns nil for streaming RPCs (events
  /// and pull), which push frames back via `session.send` from
  /// a detached Task.
  func handle(request: BrokerRequest) -> BrokerResponse? {
    switch request {
    case .health:
      return .ok

    case .loaded:
      return runBlockingResponse { try await self.loaded() }

    case .preload(let request):
      return runBlockingResponse { try await self.preload(request: request) }

    case .unload(let request):
      return runBlockingResponse { try await self.unload(request: request) }

    case .embed(let model, let inputs):
      return runBlockingResponse { try await self.embed(model: model, inputs: inputs) }

    case .pullStart(let slug):
      // Streaming: ack with .ok synchronously, then fan out progress frames
      // back to the client via the bound session.
      startPull(slug: slug)
      return .ok
    case .events:
      startEvents()
      return .ok
    }
  }

  func handleCancellation(reason: String) {
    queue.sync {
      log.notice("xpc.session_canceled reason=\(reason, privacy: .public)")
      eventTask?.cancel()
      eventTask = nil
      session = nil
    }
  }

  // MARK: - Reply-bearing handlers

  private func loaded() async throws -> BrokerResponse {
    let snap = await state.router.snapshot()
    return .loaded(brokerLoadedSnapshot(state: state, snap: snap))
  }

  private func preload(request: ModelLoadRequest) async throws -> BrokerResponse {
    do {
      return .preloaded(try await performModelLoad(state: state, request: request))
    } catch let error as BrokerError {
      return .error(error)
    } catch {
      log.error(
        "xpc.preload_failed model=\(request.model, privacy: .public) err=\(String(describing: error), privacy: .public)"
      )
      return .error(BrokerError(kind: .launchFailed, message: "\(error)"))
    }
  }

  private func unload(request: ModelUnloadRequest) async throws -> BrokerResponse {
    do {
      return .unloaded(try await performModelUnload(state: state, request: request))
    } catch let error as BrokerError {
      return .error(error)
    }
  }

  private func embed(model: String, inputs: [String]) async throws -> BrokerResponse {
    guard let descriptor = state.resolve(id: model) else {
      return .error(BrokerError(kind: .modelNotFound, message: "unknown model \(model)"))
    }
    guard descriptor.kind == .embedding else {
      return .error(BrokerError(
        kind: .wrongKindForEmbedding,
        message: "model \(model) is not an embedding model"
      ))
    }
    let intervalState = signposter.beginInterval(
      "xpc.embed",
      id: signposter.makeSignpostID(),
      "model=\(descriptor.id, privacy: .public) count=\(inputs.count, privacy: .public)"
    )
    defer { signposter.endInterval("xpc.embed", intervalState) }
    let requestID = UUID()
    let requestIDString = requestID.uuidString
    let receivedContext = TraceContext(
      modelID: descriptor.id,
      modelKind: .embedding,
      requestID: requestID
    )
    BackendTrace.notice(
      phase: TracePhase.Broker.requestReceived.rawValue,
      context: receivedContext,
      snapshot: .current(),
      extras: ["transport": "xpc", "input_count": "\(inputs.count)"]
    )
    log.notice("embedding.request_started request_id=\(requestIDString, privacy: .public) transport=xpc model=\(descriptor.id, privacy: .public) count=\(inputs.count, privacy: .public)")
    BackendTrace.notice(
      phase: TracePhase.Broker.requestStarted.rawValue,
      context: receivedContext,
      snapshot: .current(),
      extras: ["transport": "xpc", "input_count": "\(inputs.count)"]
    )

    let backend: EmbeddingBackendProtocol
    do {
      backend = try await state.router.routeEmbeddingAndBegin(descriptor)
    } catch {
      log.error("embedding.request_failed request_id=\(requestIDString, privacy: .public) transport=xpc model=\(descriptor.id, privacy: .public) count=\(inputs.count, privacy: .public) stage=route err=\(String(describing: error), privacy: .public)")
      BackendTrace.notice(
        phase: TracePhase.Broker.requestFailed.rawValue,
        context: receivedContext,
        snapshot: .current(),
        extras: [
          "transport": "xpc",
          "stage": "route",
          "error": String(describing: error),
        ]
      )
      return .error(BrokerError(kind: .embeddingFailed, message: "route: \(error)"))
    }

    let routerInfo = await state.router.embeddingLoadInfo(modelID: descriptor.id)
    let routedContext = TraceContext(
      modelID: descriptor.id,
      modelKind: .embedding,
      loadID: routerInfo?.loadID,
      backendObjectID: routerInfo?.backendObjectID,
      requestID: requestID
    )
    BackendTrace.notice(
      phase: TracePhase.Broker.requestRouted.rawValue,
      context: routedContext,
      snapshot: .current(),
      extras: ["transport": "xpc"]
    )

    do {
      let vectors = try await TraceTaskLocal.$requestID.withValue(requestID) {
        try await TraceTaskLocal.$loadID.withValue(routerInfo?.loadID) {
          try await TraceTaskLocal.$backendObjectID.withValue(routerInfo?.backendObjectID) {
            try await backend.embed(inputs: inputs)
          }
        }
      }
      await state.router.embeddingRequestDone(modelID: descriptor.id)
      BackendTrace.notice(
        phase: TracePhase.Broker.requestDoneAck.rawValue,
        context: routedContext,
        snapshot: .current(),
        extras: ["transport": "xpc", "vectors": "\(vectors.count)"]
      )
      log.notice("embedding.request_completed request_id=\(requestIDString, privacy: .public) transport=xpc model=\(descriptor.id, privacy: .public) count=\(inputs.count, privacy: .public) vectors=\(vectors.count, privacy: .public)")
      BackendTrace.notice(
        phase: TracePhase.Broker.requestCompleted.rawValue,
        context: routedContext,
        snapshot: .current(),
        extras: ["transport": "xpc", "vectors": "\(vectors.count)"]
      )
      BackendTrace.notice(
        phase: TracePhase.Broker.requestResponseSent.rawValue,
        context: routedContext,
        snapshot: .current(),
        extras: ["transport": "xpc", "vectors": "\(vectors.count)"]
      )
      return .embeddings(vectors)
    } catch {
      await state.router.embeddingRequestDone(modelID: descriptor.id)
      log.error("embedding.request_failed request_id=\(requestIDString, privacy: .public) transport=xpc model=\(descriptor.id, privacy: .public) count=\(inputs.count, privacy: .public) stage=embed err=\(String(describing: error), privacy: .public)")
      BackendTrace.notice(
        phase: TracePhase.Broker.requestFailed.rawValue,
        context: routedContext,
        snapshot: .current(),
        extras: [
          "transport": "xpc",
          "stage": "embed",
          "error": String(describing: error),
        ]
      )
      return .error(BrokerError(kind: .embeddingFailed, message: "\(error)"))
    }
  }

  // MARK: - Streaming pull

  private func startPull(slug: String) {
    let session = queue.sync { self.session }
    guard let session else {
      log.fault("xpc.pull_no_session slug=\(slug, privacy: .public)")
      return
    }
    Task.detached { [state] in
      let intervalState = signposter.beginInterval(
        "xpc.pull",
        id: signposter.makeSignpostID(),
        "slug=\(slug, privacy: .public)"
      )
      defer { signposter.endInterval("xpc.pull", intervalState) }
      log.notice("xpc.pull_started slug=\(slug, privacy: .public)")
      var destination: String?
      do {
        let stream = state.downloadCoordinator.start(slug: slug)
        for try await event in stream {
          switch event {
          case .started(let eventSlug, let eventDestination):
            destination = eventDestination
            log.notice(
              "xpc.pull_event_started slug=\(eventSlug, privacy: .public) destination=\(eventDestination, privacy: .public)"
            )
          case .progress(let line):
            log.debug("xpc.pull_event_progress slug=\(slug, privacy: .public) line=\(line, privacy: .public)")
          }
          do {
            try session.send(BrokerResponse.pullEvent(event))
          } catch {
            log.error("xpc.pull_send_failed slug=\(slug, privacy: .public) err=\(String(describing: error), privacy: .public)")
            return
          }
        }
        guard let destination else {
          let payload = BrokerError(
            kind: .pullFailed,
            message: "pull stream ended without destination"
          )
          try session.send(BrokerResponse.error(payload))
          return
        }
        log.notice("xpc.pull_completed slug=\(slug, privacy: .public) destination=\(destination, privacy: .public)")
        try session.send(BrokerResponse.pullCompleted(slug: slug, destination: destination))
      } catch {
        let payload = BrokerError(kind: .pullFailed, message: "\(error)")
        do {
          try session.send(BrokerResponse.error(payload))
        } catch {
          log.error("xpc.pull_send_failed slug=\(slug, privacy: .public) err=\(String(describing: error), privacy: .public)")
        }
      }
    }
  }

  // MARK: - Streaming broker events

  private func startEvents() {
    let session = queue.sync { self.session }
    guard let session else {
      log.fault("xpc.events_no_session")
      return
    }
    queue.sync {
      eventTask?.cancel()
      eventTask = Task.detached { [session] in
        let stream = await EventBus.shared.subscribe(backfillCount: 32)
        for await event in stream {
          do {
            try session.send(BrokerResponse.event(event))
          } catch {
            log.error("xpc.events_send_failed err=\(String(describing: error), privacy: .public)")
            return
          }
        }
      }
    }
  }

  // MARK: - Async/sync bridge

  /// Bridges the async work into the XPC handler's sync return slot.
  /// `XPCListener` calls `incomingMessageHandler` from a serial queue
  /// owned by libxpc; blocking it briefly is the documented pattern
  /// for typed reply-bearing requests.
  private func runBlockingResponse(_ work: @Sendable @escaping () async throws -> BrokerResponse) -> BrokerResponse {
    switch runBlocking(work) {
    case .success(let response):
      return response
    case .failure(let error):
      return .error(BrokerError(kind: .internalError, message: "\(error)"))
    }
  }
}
