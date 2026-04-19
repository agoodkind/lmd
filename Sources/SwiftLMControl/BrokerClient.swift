//
//  BrokerClient.swift
//  SwiftLMControl
//
//  Created by Alex Goodkind <alex@goodkind.io> on 2026-04-19.
//  Copyright © 2026
//
//  Async client for the broker's XPC control surface. Wraps `XPCSession`
//  with a typed Codable request/response API that mirrors `BrokerRequest`
//  and `BrokerResponse`.
//
//  Transport: the LaunchAgent registers `io.goodkind.lmd.control` as a
//  Mach service, so a fresh `XPCSession` either connects to a running
//  daemon or causes launchd to demand-start one. There is no port to
//  configure and no LMD_HOST/LMD_PORT to drift.
//

import AppLogger
import Foundation
import SwiftLMRuntime
import XPC

private let log = AppLogger.logger(category: "BrokerClient")

// MARK: - Errors

public enum BrokerClientError: Error, Sendable {
  case sessionUnavailable(message: String)
  case unexpectedResponse(message: String)
  case streamFailed(message: String)
}

// MARK: - Client

/// Send Codable messages to the broker over XPC.
///
/// Threading: the underlying `XPCSession` is itself thread-safe (FIFO
/// per Apple docs), so this is a `final class` rather than an actor to
/// avoid extra hops on the hot path. Each public method awaits via a
/// continuation; concurrent calls are serialized inside XPC.
public final class BrokerClient: @unchecked Sendable {
  private let session: XPCSession
  private let pullDelegate: PullEventDelegate
  private let eventDelegate: BrokerEventDelegate
  // XPCSession traps with `_xpc_api_misuse` if it is released while
  // still active. We must call `cancel()` exactly once before the
  // session deallocates; the flag guards against double-cancel from
  // an explicit close() followed by deinit.
  private let closedLock = NSLock()
  private var closed = false

  /// Create and activate a session bound to the broker Mach service.
  ///
  /// Throws `BrokerClientError.sessionUnavailable` when launchd cannot
  /// locate the service (most often: the LaunchAgent plist is not
  /// installed or has not been bootstrapped).
  public init(serviceName: String = brokerXPCServiceName) throws {
    self.pullDelegate = PullEventDelegate()
    self.eventDelegate = BrokerEventDelegate()
    let pullDelegate = self.pullDelegate
    let eventDelegate = self.eventDelegate
    // The session multiplexes one request/reply RPC stream and, for
    // pulls, a server-initiated message stream that flows back through
    // the incomingMessageHandler. The decodable-handler overload
    // requires the closure to return `(any Encodable)?`; we never
    // respond from the client side, so always return nil.
    do {
      self.session = try XPCSession(
        machService: serviceName,
        incomingMessageHandler: { (response: BrokerResponse) -> (any Encodable)? in
          pullDelegate.deliver(response)
          eventDelegate.deliver(response)
          return nil
        },
        cancellationHandler: { reason in
          pullDelegate.cancel(reason: String(describing: reason))
          eventDelegate.cancel(reason: String(describing: reason))
        }
      )
    } catch {
      log.error("client.session_unavailable service=\(serviceName, privacy: .public) err=\(String(describing: error), privacy: .public)")
      throw BrokerClientError.sessionUnavailable(message: "\(error)")
    }
    log.info("client.session_opened service=\(serviceName, privacy: .public)")
  }

  deinit {
    cancelOnce()
  }

  /// Explicitly tear down the underlying XPC session. Safe to call
  /// multiple times. CLI subcommands should `defer client.close()`
  /// before `exit(...)` so the session is cancelled on a known
  /// thread, not during process teardown where deinit ordering
  /// against libxpc's worker queues is unspecified.
  public func close() {
    cancelOnce()
  }

  private func cancelOnce() {
    closedLock.lock()
    let alreadyClosed = closed
    closed = true
    closedLock.unlock()
    if alreadyClosed {
      return
    }
    session.cancel(reason: "client closed")
    log.info("client.session_closed")
  }

  // MARK: - Simple RPCs

  public func health() async throws {
    let reply = try await sendForReply(.health)
    try expectOK(reply)
  }

  public func loaded() async throws -> LoadedSnapshot {
    let reply = try await sendForReply(.loaded)
    switch reply {
    case .loaded(let snapshot):
      return snapshot
    case .error(let err):
      throw err
    default:
      throw BrokerClientError.unexpectedResponse(message: "expected .loaded, got \(reply)")
    }
  }

  public func preload(model: String) async throws {
    let reply = try await sendForReply(.preload(model: model))
    switch reply {
    case .preloaded:
      return
    case .error(let err):
      throw err
    default:
      throw BrokerClientError.unexpectedResponse(message: "expected .preloaded, got \(reply)")
    }
  }

  public func unload(model: String) async throws {
    let reply = try await sendForReply(.unload(model: model))
    switch reply {
    case .unloaded:
      return
    case .error(let err):
      throw err
    default:
      throw BrokerClientError.unexpectedResponse(message: "expected .unloaded, got \(reply)")
    }
  }

  public func embed(model: String, inputs: [String]) async throws -> [[Float]] {
    let reply = try await sendForReply(.embed(model: model, inputs: inputs))
    switch reply {
    case .embeddings(let vectors):
      return vectors
    case .error(let err):
      throw err
    default:
      throw BrokerClientError.unexpectedResponse(message: "expected .embeddings, got \(reply)")
    }
  }

  // MARK: - Streaming events

  /// Subscribe to broker lifecycle events. The stream includes a
  /// backfill from the shared bus plus live events until the broker
  /// connection closes.
  public func events() -> AsyncThrowingStream<BrokerEvent, Error> {
    let stream = eventDelegate.makeStream()
    do {
      try session.send(BrokerRequest.events) { [weak self] (result: Result<BrokerResponse, Error>) in
        guard let self else { return }
        switch result {
        case .success(let response):
          switch response {
          case .ok:
            return
          case .error(let err):
            self.eventDelegate.fail(err)
          default:
            self.eventDelegate.fail(
              BrokerError(kind: .internalError, message: "unexpected start response: \(response)")
            )
          }
        case .failure(let err):
          self.eventDelegate.fail(BrokerError(kind: .internalError, message: "\(err)"))
        }
      }
    } catch {
      eventDelegate.fail(BrokerError(kind: .internalError, message: "\(error)"))
    }
    return stream
  }

  // MARK: - Streaming pull

  /// Start a model pull and yield each progress event. The stream
  /// terminates with `pullCompleted` (success) or throws on `error`.
  ///
  /// The broker sends frames as server-initiated messages on the same
  /// session, decoded by `pullDelegate`. The initial `sendForReply`
  /// receives an immediate `.ok` ack so the client knows the session is
  /// live before it starts awaiting frames.
  public func pull(slug: String) -> AsyncThrowingStream<PullEvent, Error> {
    let stream = pullDelegate.makeStream()
    log.notice("client.pull_started slug=\(slug, privacy: .public)")
    do {
      try session.send(BrokerRequest.pullStart(slug: slug)) { [weak self] (result: Result<BrokerResponse, Error>) in
        switch result {
        case .success(let response):
          if case .error(let err) = response {
            self?.pullDelegate.fail(err)
          }
        case .failure(let err):
          self?.pullDelegate.fail(BrokerError(kind: .pullFailed, message: "\(err)"))
        }
      }
    } catch {
      log.error("client.pull_send_failed slug=\(slug, privacy: .public) err=\(String(describing: error), privacy: .public)")
      pullDelegate.fail(BrokerError(kind: .pullFailed, message: "\(error)"))
    }
    return stream
  }

  // MARK: - Internals

  private func sendForReply(_ request: BrokerRequest) async throws -> BrokerResponse {
    try await withCheckedThrowingContinuation { continuation in
      do {
        try session.send(request) { (result: Result<BrokerResponse, Error>) in
          switch result {
          case .success(let response):
            continuation.resume(returning: response)
          case .failure(let err):
            continuation.resume(throwing: err)
          }
        }
      } catch {
        continuation.resume(throwing: error)
      }
    }
  }

  private func expectOK(_ response: BrokerResponse) throws {
    switch response {
    case .ok:
      return
    case .error(let err):
      throw err
    default:
      throw BrokerClientError.unexpectedResponse(message: "expected .ok, got \(response)")
    }
  }
}

// MARK: - Pull event fanout

/// Routes server-initiated `BrokerResponse.pullEvent` messages into the
/// most recent `AsyncThrowingStream` returned by `pull(slug:)`.
///
/// One pull at a time per `BrokerClient`; calling `pull` again replaces
/// the active continuation. That matches the CLI use case (one
/// foreground pull) and avoids the bookkeeping of multiplexing pulls
/// over a single session.
private final class PullEventDelegate: @unchecked Sendable {
  private let queue = DispatchQueue(label: "io.goodkind.lmd.brokerclient.pull")
  private var continuation: AsyncThrowingStream<PullEvent, Error>.Continuation?

  func makeStream() -> AsyncThrowingStream<PullEvent, Error> {
    AsyncThrowingStream { cont in
      queue.sync {
        continuation?.finish()
        continuation = cont
      }
    }
  }

  func deliver(_ response: BrokerResponse) {
    queue.sync {
      switch response {
      case .pullEvent(let event):
        continuation?.yield(event)
      case .pullCompleted:
        continuation?.finish()
        continuation = nil
      case .error(let err):
        continuation?.finish(throwing: err)
        continuation = nil
      case .event:
        return
      default:
        // Reply-handler RPCs (loaded/embeddings/etc.) are delivered
        // through the per-message reply continuation, not here. Anything
        // that lands in this branch is a server bug or a stale stream.
        log.fault("client.unexpected_streamed_response type=\(String(describing: response), privacy: .public)")
      }
    }
  }

  func fail(_ err: BrokerError) {
    queue.sync {
      continuation?.finish(throwing: err)
      continuation = nil
    }
  }

  func cancel(reason: String) {
    queue.sync {
      continuation?.finish(throwing: BrokerError(kind: .internalError, message: "session canceled: \(reason)"))
      continuation = nil
    }
  }
}

// MARK: - Broker event fanout

/// Routes server-initiated `BrokerResponse.event` messages into the latest
/// event stream returned by `events()`.
private final class BrokerEventDelegate: @unchecked Sendable {
  private let queue = DispatchQueue(label: "io.goodkind.lmd.brokerclient.events")
  private var continuation: AsyncThrowingStream<BrokerEvent, Error>.Continuation?

  func makeStream() -> AsyncThrowingStream<BrokerEvent, Error> {
    AsyncThrowingStream { cont in
      queue.sync {
        continuation?.finish()
        continuation = cont
      }
    }
  }

  func deliver(_ response: BrokerResponse) {
    queue.sync {
      switch response {
      case .event(let event):
        continuation?.yield(event)
      default:
        break
      }
    }
  }

  func fail(_ err: BrokerError) {
    queue.sync {
      continuation?.finish(throwing: err)
      continuation = nil
    }
  }

  func cancel(reason: String) {
    queue.sync {
      continuation?.finish(throwing: BrokerError(kind: .internalError, message: "session canceled: \(reason)"))
      continuation = nil
    }
  }
}
