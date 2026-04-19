//
//  EventBus.swift
//  SwiftLMRuntime
//
//  Created by Alex Goodkind <alex@goodkind.io> on 2026-04-18.
//  Copyright © 2026
//
//  Tiny in-process pub/sub. Producers publish structured events; the
//  broker's `/swiftlmd/events` route and the TUI's EventsTab subscribe.
//  Keeps the last N events in a ring so a late subscriber can backfill.
//

import AppLogger
import Foundation

private let log = AppLogger.logger(category: "Broker")

/// One published event. Values go across the network as JSON so the
/// shape stays stable.
public struct BrokerEvent: Sendable, Hashable, Codable {
  public let kind: Kind
  public let ts: Date
  public let model: String?
  public let message: String

  public enum Kind: String, Sendable, Codable {
    case modelLoaded = "model.loaded"
    case modelUnloaded = "model.unloaded"
    case modelEvicted = "model.evicted"
    case requestStarted = "request.started"
    case requestCompleted = "request.completed"
    case requestFailed = "request.failed"
    case pullStarted = "pull.started"
    case pullProgress = "pull.progress"
    case pullCompleted = "pull.completed"
    case note = "note"
  }

  public init(kind: Kind, model: String? = nil, message: String = "", ts: Date = Date()) {
    self.kind = kind
    self.ts = ts
    self.model = model
    self.message = message
  }
}

/// Shared event bus. `shared` is an actor so multiple async callers
/// can publish and subscribe safely.
public actor EventBus {
  public static let shared = EventBus()

  private var ring: [BrokerEvent] = []
  private let ringCap: Int
  private var subscribers: [UUID: AsyncStream<BrokerEvent>.Continuation] = [:]

  public init(ringCap: Int = 1024) {
    self.ringCap = max(64, ringCap)
  }

  /// Publish an event. Appends to the ring and fans out to subscribers.
  public func publish(_ event: BrokerEvent) {
    ring.append(event)
    if ring.count > ringCap { ring.removeFirst(ring.count - ringCap) }
    for (_, cont) in subscribers { cont.yield(event) }
  }

  /// Convenience for call sites that don't want to build a BrokerEvent.
  public func publish(kind: BrokerEvent.Kind, model: String? = nil, message: String = "") {
    publish(BrokerEvent(kind: kind, model: model, message: message))
  }

  /// Subscribe. Returns a stream that yields every future event plus a
  /// prefix of up to `backfillCount` buffered past events.
  public func subscribe(backfillCount: Int = 0) -> AsyncStream<BrokerEvent> {
    let id = UUID()
    let backlog = backfillCount > 0 ? Array(ring.suffix(backfillCount)) : []

    return AsyncStream { cont in
      for ev in backlog { cont.yield(ev) }
      Task { [weak self] in
        await self?.register(id: id, cont: cont)
      }
      cont.onTermination = { [weak self] _ in
        Task { [weak self] in
          await self?.deregister(id: id)
        }
      }
    }
  }

  private func register(id: UUID, cont: AsyncStream<BrokerEvent>.Continuation) {
    subscribers[id] = cont
  }

  private func deregister(id: UUID) {
    subscribers.removeValue(forKey: id)
  }

  /// Current ring-buffer snapshot, newest last. Useful for tests.
  public func snapshot() -> [BrokerEvent] { ring }
}
