//
//  TraceRingBuffer.swift
//  SwiftLMMetrics
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-06-06.
//  Copyright © 2026, all rights reserved.
//
//  Bounded in-memory trace storage for metrics snapshots.
//

import Foundation

public struct TraceRingBuffer: Sendable {
  private let capacity: Int
  private var spans: [MetricsTraceSpan] = []

  public init(capacity: Int = 512) {
    self.capacity = max(1, capacity)
  }

  public mutating func append(_ span: MetricsTraceSpan) {
    spans.append(span)
    if spans.count > capacity {
      spans.removeFirst(spans.count - capacity)
    }
  }

  public func snapshot() -> [MetricsTraceSpan] {
    spans
  }
}
