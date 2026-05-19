//
//  TraceTaskLocal.swift
//  SwiftLMTrace
//
//  Created by Alex Goodkind <alex@goodkind.io> on 2026-05-18.
//  Copyright © 2026
//
//  Task-local correlators used by backends to enrich per-request traces.
//
//  The broker layer knows both the routed `loadID` and the inbound
//  `requestID`. Backends do not, since they predate either correlator.
//  Setting these task-local values around the backend invocation lets
//  the backend emit per-phase traces with both correlators attached
//  without changing the `EmbeddingBackendProtocol.embed` signature.
//

import Foundation

public enum TraceTaskLocal {
  /// Stable router-side load identifier for the resolved backend.
  @TaskLocal public static var loadID: UUID?
  /// Backend identity hash for the resolved backend.
  @TaskLocal public static var backendObjectID: String?
  /// Per-request correlation id assigned at the transport entry point.
  @TaskLocal public static var requestID: UUID?
}
