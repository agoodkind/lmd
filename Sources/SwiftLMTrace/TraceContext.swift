//
//  TraceContext.swift
//  SwiftLMTrace
//
//  Created by Alex Goodkind <alex@goodkind.io> on 2026-05-18.
//  Copyright © 2026
//
//  Carrier for the standard identifying fields on every BackendTrace line.
//

import Foundation

/// Kind of backend a trace line is associated with.
///
/// This is intentionally distinct from `SwiftLMCore.ModelKind`. The
/// trace plane distinguishes `video` from `chat` because video
/// generation has its own request-phase shape, even though the router
/// treats both as the same routing kind.
public enum BackendKind: String, Sendable {
  case chat
  case embedding
  case video
}

/// Identifying context for a single trace line.
///
/// Every `BackendTrace` line carries `model`, `model_kind`, optional
/// `load_id`, optional `backend_obj`, and optional `request_id`. This
/// struct is the shape of those fields so call sites can construct the
/// context once per scope and reuse it for many phases.
public struct TraceContext: Sendable {
  public let modelID: String
  public let modelKind: BackendKind
  public let loadID: UUID?
  public let backendObjectID: String?
  public let requestID: UUID?

  public init(
    modelID: String,
    modelKind: BackendKind,
    loadID: UUID? = nil,
    backendObjectID: String? = nil,
    requestID: UUID? = nil
  ) {
    self.modelID = modelID
    self.modelKind = modelKind
    self.loadID = loadID
    self.backendObjectID = backendObjectID
    self.requestID = requestID
  }

  /// Return a copy with a request-scoped id attached.
  public func with(requestID: UUID?) -> TraceContext {
    TraceContext(
      modelID: modelID,
      modelKind: modelKind,
      loadID: loadID,
      backendObjectID: backendObjectID,
      requestID: requestID
    )
  }

  /// Return a copy with a load id attached.
  public func with(loadID: UUID?) -> TraceContext {
    TraceContext(
      modelID: modelID,
      modelKind: modelKind,
      loadID: loadID,
      backendObjectID: backendObjectID,
      requestID: requestID
    )
  }

  /// Stable, low-cardinality identity for a backend reference. We hash
  /// `ObjectIdentifier` rather than embed the raw pointer because the
  /// hash is enough to detect a re-spawn while remaining safe to log.
  public static func backendObjectID(of object: AnyObject) -> String {
    let raw = UInt(bitPattern: ObjectIdentifier(object).hashValue)
    return String(raw, radix: 16)
  }
}
