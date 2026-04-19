//
//  BrokerEventsSequence.swift
//  swiftlmd
//
//  Created by Alex Goodkind <alex@goodkind.io> on 2026-04-18.
//  Copyright © 2026
//
//  AsyncSequence adapter that bridges ``EventBus.shared.subscribe()``
//  into SSE byte frames for the `/swiftlmd/events` response body.
//  Wraps each ``BrokerEvent`` as `data: { ... json ... }\n\n`.
//

import AppLogger
import Foundation
import NIOCore
import SwiftLMRuntime

private let log = AppLogger.logger(category: "Broker")

struct BrokerEventsSequence: AsyncSequence, Sendable {
  typealias Element = ByteBuffer
  let backfillCount: Int

  init(backfillCount: Int = 32) {
    self.backfillCount = backfillCount
  }

  func makeAsyncIterator() -> Iterator {
    Iterator(backfillCount: backfillCount)
  }

  final class Iterator: AsyncIteratorProtocol {
    private let backfillCount: Int
    private var stream: AsyncStream<BrokerEvent>?
    private var cursor: AsyncStream<BrokerEvent>.AsyncIterator?

    init(backfillCount: Int) {
      self.backfillCount = backfillCount
    }

    func next() async throws -> ByteBuffer? {
      if cursor == nil {
        let s = await EventBus.shared.subscribe(backfillCount: backfillCount)
        self.stream = s
        self.cursor = s.makeAsyncIterator()
        log.info("events.subscriber_attached")
      }
      guard let ev = await cursor?.next() else { return nil }
      let encoder = JSONEncoder()
      encoder.dateEncodingStrategy = .iso8601
      guard let data = try? encoder.encode(ev) else { return nil }
      let line = "data: \(String(data: data, encoding: .utf8) ?? "{}")\n\n"
      return ByteBuffer(string: line)
    }
  }
}
