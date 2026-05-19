//
//  Tracer.swift
//  SwiftLMTrace
//
//  Created by Alex Goodkind <alex@goodkind.io> on 2026-05-18.
//  Copyright © 2026
//
//  Scope helper that binds a TraceContext and forwards into BackendTrace.
//  Each call site that emits many phases for the same model/load/backend
//  builds a Tracer once and calls `notice` or `debug` for each phase
//  without repeating the context.
//

import Foundation

public struct Tracer: Sendable {
  public let context: TraceContext

  public init(context: TraceContext) {
    self.context = context
  }

  public func notice(
    _ phase: String,
    snapshot: MemorySnapshot? = nil,
    extras: [String: String] = [:]
  ) {
    BackendTrace.notice(
      phase: phase,
      context: context,
      snapshot: snapshot,
      extras: extras
    )
  }

  public func debug(
    _ phase: String,
    snapshot: MemorySnapshot? = nil,
    extras: [String: String] = [:]
  ) {
    BackendTrace.debug(
      phase: phase,
      context: context,
      snapshot: snapshot,
      extras: extras
    )
  }

  /// Variant that takes a fresh memory snapshot on emit. Use when the
  /// caller does not already have a snapshot in scope.
  public func noticeWithCurrentSnapshot(
    _ phase: String,
    extras: [String: String] = [:]
  ) {
    notice(phase, snapshot: .current(), extras: extras)
  }

  /// Variant that takes a fresh memory snapshot on emit (debug level).
  public func debugWithCurrentSnapshot(
    _ phase: String,
    extras: [String: String] = [:]
  ) {
    debug(phase, snapshot: .current(), extras: extras)
  }

  /// Return a new tracer with the same model/load/backend identity but a
  /// scoped request id. Use at the top of every request handler so all
  /// per-request phases share one correlator.
  public func scoped(requestID: UUID) -> Tracer {
    Tracer(context: context.with(requestID: requestID))
  }
}
