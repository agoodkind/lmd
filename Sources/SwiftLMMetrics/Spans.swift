//
//  Spans.swift
//  SwiftLMMetrics
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-06-07.
//  Copyright © 2026, all rights reserved.
//
//  Distributed-tracing helpers over swift-distributed-tracing. withRequestSpan
//  opens a server span around a request so its phase marks become child spans
//  in the same task-local context, which renders in Tempo as a request span
//  with phase children. addSpanEvent opens a short child span for one phase.
//
//  Both are free when no collector is configured: InstrumentationSystem defaults
//  to the no-op tracer until SwiftLMMetricsOTel bootstraps the OTLP tracer behind
//  the OTEL_EXPORTER_OTLP_ENDPOINT gate, so these cost nothing when export is off.
//

import Foundation
import Tracing

extension SwiftLMMetrics {
  /// Run `body` inside a server span named `name`, stamped with the request's
  /// model identity. The span ends automatically and records any thrown error.
  /// Phase marks emitted via ``addSpanEvent`` during `body` attach as children
  /// because they share the task-local span context this opens.
  @discardableResult
  public static func withRequestSpan<T>(
    _ name: String,
    modelID: String,
    modelKind: String,
    requestID: UUID?,
    attributes: [String: String] = [:],
    isolation _: isolated (any Actor)? = #isolation,
    _ body: () async throws -> T
  ) async rethrows -> T {
    try await withSpan(name, ofKind: .server) { span in
      span.updateAttributes { stamped in
        stamped["model_id"] = modelID
        stamped["model_kind"] = modelKind
        if let requestID {
          stamped["request_id"] = requestID.uuidString
        }
        for (key, value) in attributes {
          stamped[key] = value
        }
      }
      return try await body()
    }
  }

  /// Emit one phase as a short child span under the current request span. A
  /// no-op tracer drops it; the OTLP tracer exports it as a child in Tempo.
  public static func addSpanEvent(_ name: String, attributes: [String: String] = [:]) {
    withSpan(name, ofKind: .internal) { span in
      for (key, value) in attributes {
        span.attributes[key] = value
      }
    }
  }
}
