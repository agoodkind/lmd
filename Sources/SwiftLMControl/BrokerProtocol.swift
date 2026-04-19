//
//  BrokerProtocol.swift
//  SwiftLMControl
//
//  Created by Alex Goodkind <alex@goodkind.io> on 2026-04-19.
//  Copyright © 2026
//
//  Wire protocol for the broker's XPC control surface. The Codable enums
//  here are the single source of truth shared by `lmd-serve` (server)
//  and the first-party Swift CLIs (`lmd`, `lmd-tui`) via `BrokerClient`.
//
//  This protocol is in-process loopback only. External HTTP callers
//  (clyde and friends) keep talking to Hummingbird; their JSON shape is
//  defined at the route handlers, not here.
//

import Foundation
import SwiftLMRuntime

/// Mach service name registered by the LaunchAgent and the only way
/// in-process Swift callers locate the broker. Bumping this string is a
/// breaking change for installed plists.
public let brokerXPCServiceName = "io.goodkind.lmd.control"

// MARK: - Request

/// Every request the CLI/TUI can issue to the broker over XPC.
///
/// Keep cases small and unambiguous. Prefer adding a new case to
/// overloading an existing one with optional fields. The handler-side
/// switch is the contract.
public enum BrokerRequest: Codable, Sendable {
  case health
  case loaded
  case preload(model: String)
  case unload(model: String)
  case pullStart(slug: String)
  case embed(model: String, inputs: [String])
  case events
}

// MARK: - Response

/// Every response (or streamed frame) the broker can send.
///
/// `pullEvent` is special: a `pullStart` request opens a session whose
/// reply stream emits one `pullEvent` per progress notification, then
/// terminates with `pullCompleted` or `error`.
public enum BrokerResponse: Codable, Sendable {
  case ok
  case loaded(LoadedSnapshot)
  case preloaded(modelID: String)
  case unloaded(modelID: String)
  case event(BrokerEvent)
  case pullEvent(PullEvent)
  case pullCompleted(slug: String, destination: String)
  case embeddings([[Float]])
  case error(BrokerError)
}

// MARK: - Payload types

/// Snapshot of every model currently loaded into the router. Mirrors
/// the JSON shape the Hummingbird `/swiftlmd/loaded` route serves so
/// HTTP and XPC clients see the same numbers.
public struct LoadedSnapshot: Codable, Sendable {
  public let allocatedGB: Double
  public let models: [LoadedModel]

  public init(allocatedGB: Double, models: [LoadedModel]) {
    self.allocatedGB = allocatedGB
    self.models = models
  }

  public struct LoadedModel: Codable, Sendable {
    public let modelID: String
    public let sizeGB: Double
    public let lastUsed: Date
    public let inFlightRequests: Int
    public let kind: String

    public init(
      modelID: String,
      sizeGB: Double,
      lastUsed: Date,
      inFlightRequests: Int,
      kind: String
    ) {
      self.modelID = modelID
      self.sizeGB = sizeGB
      self.lastUsed = lastUsed
      self.inFlightRequests = inFlightRequests
      self.kind = kind
    }
  }
}

/// One progress frame from a `pullStart` stream. `progress` carries the
/// raw line emitted by the downloader so the CLI can render it without
/// the broker having to parse percentages.
public enum PullEvent: Codable, Sendable {
  case started(slug: String, destination: String)
  case progress(line: String)
}

/// Structured failure envelope. `kind` is a stable machine token; HTTP
/// callers see the equivalent `type` field in the JSON error envelope.
public struct BrokerError: Codable, Sendable, Error {
  public let kind: Kind
  public let message: String

  public init(kind: Kind, message: String) {
    self.kind = kind
    self.message = message
  }

  public enum Kind: String, Codable, Sendable {
    case invalidRequest = "invalid_request"
    case modelNotFound = "model_not_found"
    case wrongKindForChat = "wrong_kind_for_chat"
    case wrongKindForEmbedding = "wrong_kind_for_embedding"
    case capacityExceeded = "capacity_exceeded"
    case launchFailed = "launch_failed"
    case embeddingFailed = "embedding_failed"
    case notConfigured = "not_configured"
    case pullFailed = "pull_failed"
    case unauthorized = "unauthorized"
    case internalError = "internal_error"
  }
}
