//
//  SwiftLogBridge.swift
//  AppLogger
//
//  Created by Alex Goodkind <alex@goodkind.io> on 2026-04-18.
//  Copyright © 2026
//
//  `swift-log` → `os.Logger` adapter. `AppLogger.bootstrap` installs one
//  of these per swift-log category so every transitive dependency
//  (Hummingbird, async-http-client, swift-nio, swift-service-lifecycle)
//  lands under the shared subsystem.
//
//  This is the ONLY file in the project that may `import Logging`.
//  Enforced by `make log-audit`.
//

import Foundation
import Logging
import os

/// `LogHandler` that forwards every `swift-log` event to an `os.Logger`.
///
/// The bridge maps swift-log's five levels onto the closest `OSLogType`
/// equivalent and renders the message + metadata as a single
/// public-annotated interpolation. Metadata stays coarse on purpose.
/// Fine-grained privacy annotation belongs to first-party call sites
/// that use `os.Logger` directly.
struct SwiftLogToOSLogBackend: LogHandler {
  var metadata: Logging.Logger.Metadata = [:]
  var logLevel: Logging.Logger.Level = .info
  private let osLogger: os.Logger

  init(subsystem: String, category: String) {
    self.osLogger = os.Logger(subsystem: subsystem, category: category)
  }

  subscript(metadataKey key: String) -> Logging.Logger.Metadata.Value? {
    get { metadata[key] }
    set { metadata[key] = newValue }
  }

  /// Modern swift-log entry point. The legacy
  /// `log(level:message:metadata:source:file:function:line:)` default
  /// implementation forwards here via swift-log's own shim, so this
  /// one method covers both call paths.
  func log(event: Logging.LogEvent) {
    let merged = mergeMetadata(handler: self.metadata, event: event.metadata)
    let meta = renderMetadata(merged)
    let osType = Self.mapLevel(event.level)
    if meta.isEmpty {
      osLogger.log(
        level: osType,
        "\(event.message.description, privacy: .public)"
      )
    } else {
      osLogger.log(
        level: osType,
        "\(event.message.description, privacy: .public) meta=\(meta, privacy: .public)"
      )
    }
  }

  // MARK: - Internals

  private func mergeMetadata(
    handler: Logging.Logger.Metadata,
    event: Logging.Logger.Metadata?
  ) -> Logging.Logger.Metadata {
    guard let event = event, !event.isEmpty else { return handler }
    var out = handler
    for (k, v) in event { out[k] = v }
    return out
  }

  private func renderMetadata(_ m: Logging.Logger.Metadata) -> String {
    if m.isEmpty { return "" }
    let pairs = m.sorted { $0.key < $1.key }
      .map { "\($0.key)=\(describe($0.value))" }
    return pairs.joined(separator: " ")
  }

  private func describe(_ v: Logging.Logger.MetadataValue) -> String {
    switch v {
    case .string(let s): return s
    case .stringConvertible(let s): return s.description
    case .array(let a): return "[" + a.map(describe).joined(separator: ",") + "]"
    case .dictionary(let d):
      return "{" + d.sorted { $0.key < $1.key }
        .map { "\($0.key):\(describe($0.value))" }
        .joined(separator: ",") + "}"
    }
  }

  private static func mapLevel(_ level: Logging.Logger.Level) -> OSLogType {
    switch level {
    case .trace, .debug: return .debug
    case .info, .notice: return .info
    case .warning, .error: return .error
    case .critical: return .fault
    }
  }
}
