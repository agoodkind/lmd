//
//  BackendTrace.swift
//  SwiftLMTrace
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-05-18.
//  Copyright © 2026, all rights reserved.
//
//  Emission layer for the BackendTrace category. Renders the standard
//  field shape and routes through AppLogger's `os.Logger` so the lines
//  show up under the same subsystem as every other log in lmd.
//
//  Standard fields on every line:
//      phase=<name> ts_mono=<ns> model=<id> model_kind=<chat|embedding|video>
//      load_id=<uuid|none> backend_obj=<addr|none> request_id=<uuid|none>
//      mlx_active=<bytes> mlx_cache=<bytes> mlx_peak=<bytes> [extras]
//

import AppLogger
import Darwin
import Foundation
import os

public enum BackendTrace {
  /// Single backing logger for the entire trace plane. Filter with
  /// `log show --predicate 'subsystem == "io.goodkind.lmd" AND category == "BackendTrace"'`.
  private static let logger = AppLogger.logger(category: "BackendTrace")

  /// Lifecycle-level trace line.
  public static func notice(
    phase: String,
    context: TraceContext,
    snapshot: MemorySnapshot? = nil,
    extras: [String: String] = [:]
  ) {
    let message = format(
      phase: phase,
      context: context,
      snapshot: snapshot,
      extras: extras
    )
    logger.notice("\(message, privacy: .public)")
  }

  /// Chatty per-request trace line. Dropped by default at production
  /// log levels; visible with `log show --debug`.
  public static func debug(
    phase: String,
    context: TraceContext,
    snapshot: MemorySnapshot? = nil,
    extras: [String: String] = [:]
  ) {
    let message = format(
      phase: phase,
      context: context,
      snapshot: snapshot,
      extras: extras
    )
    logger.debug("\(message, privacy: .public)")
  }

  /// Build the standard-field log message without emitting it. Exposed
  /// so callers that prefer to log directly can keep using their own
  /// logger handle while still producing trace-compatible lines.
  public static func format(
    phase: String,
    context: TraceContext,
    snapshot: MemorySnapshot? = nil,
    extras: [String: String] = [:]
  ) -> String {
    let snap = snapshot ?? MemorySnapshot.zero
    var parts: [String] = []
    parts.append("phase=\(phase)")
    parts.append("ts_mono=\(monoNanos())")
    parts.append("model=\(context.modelID)")
    parts.append("model_kind=\(context.modelKind.rawValue)")
    parts.append("load_id=\(context.loadID?.uuidString ?? "none")")
    parts.append("backend_obj=\(context.backendObjectID ?? "none")")
    parts.append("request_id=\(context.requestID?.uuidString ?? "none")")
    parts.append("mlx_active=\(snap.active)")
    parts.append("mlx_cache=\(snap.cache)")
    parts.append("mlx_peak=\(snap.peak)")
    for (key, value) in extras.sorted(by: { $0.key < $1.key }) {
      parts.append("\(key)=\(value)")
    }
    return parts.joined(separator: " ")
  }

  /// Monotonic nanoseconds for the `ts_mono` field. CLOCK_MONOTONIC_RAW
  /// is unaffected by wall-clock adjustments so deltas across the trace
  /// stream remain meaningful.
  private static func monoNanos() -> UInt64 {
    clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)
  }
}
