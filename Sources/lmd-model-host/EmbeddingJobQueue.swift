//
//  EmbeddingJobQueue.swift
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-06-11.
//  Copyright © 2026, all rights reserved.
//
//  Serializes embedding forwards with a two-lane wait queue. Priority waiters
//  resume before normal waiters; each lane is FIFO internally. With the lane
//  disabled every waiter joins the normal lane, giving strict FIFO. Depth and
//  wait metrics are emitted here so every consumer measures identically.
//

import Foundation
import SwiftLMMetrics

actor EmbeddingJobQueue {
  private static let nanosecondsPerSecond = 1_000_000_000.0

  private let maxConcurrent: Int
  private let laneEnabled: Bool
  private var running = 0
  private var priorityWaiters: [CheckedContinuation<Void, Never>] = []
  private var normalWaiters: [CheckedContinuation<Void, Never>] = []

  init(maxConcurrent: Int, laneEnabled: Bool) {
    self.maxConcurrent = max(maxConcurrent, 1)
    self.laneEnabled = laneEnabled
  }

  var waitingCount: Int { priorityWaiters.count + normalWaiters.count }

  func acquire(priority: Bool) async {
    if running < maxConcurrent {
      running += 1
      publishDepth()
      return
    }
    let waitStarted = DispatchTime.now()
    await withCheckedContinuation { continuation in
      if priority && laneEnabled {
        priorityWaiters.append(continuation)
      } else {
        normalWaiters.append(continuation)
      }
      publishDepth()
    }
    let waitedSeconds =
      Double(DispatchTime.now().uptimeNanoseconds - waitStarted.uptimeNanoseconds)
      / Self.nanosecondsPerSecond
    SwiftLMMetrics.observeSeconds("lmd_embed_queue_wait_seconds", waitedSeconds)
  }

  func release() {
    if !priorityWaiters.isEmpty {
      let next = priorityWaiters.removeFirst()
      publishDepth()
      // The resumed waiter inherits this slot, so `running` stays unchanged on handoff.
      next.resume()
      return
    }
    if !normalWaiters.isEmpty {
      let next = normalWaiters.removeFirst()
      publishDepth()
      // The resumed waiter inherits this slot, so `running` stays unchanged on handoff.
      next.resume()
      return
    }
    running = max(running - 1, 0)
    publishDepth()
  }

  private func publishDepth() {
    SwiftLMMetrics.setGauge("lmd_embed_queue_depth", Double(waitingCount))
  }
}
