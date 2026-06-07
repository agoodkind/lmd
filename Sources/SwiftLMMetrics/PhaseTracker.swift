//
//  PhaseTracker.swift
//  SwiftLMMetrics
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-06-06.
//  Copyright © 2026, all rights reserved.
//
//  Small request-scoped helper for code paths whose phases are visible only at
//  the caller boundary.
//

import Dispatch
import Foundation

public struct PhaseTracker: Sendable {
  private let sink: SnapshotSink
  private let modelID: String
  private let modelKind: String
  private let requestID: UUID
  private let spanName: String
  private let startedAt: Date
  private let startedNanoseconds: UInt64

  public init(
    sink: SnapshotSink = .shared,
    modelID: String,
    modelKind: String,
    requestID: UUID,
    spanName: String
  ) {
    let now = DispatchTime.now().uptimeNanoseconds
    self.sink = sink
    self.modelID = modelID
    self.modelKind = modelKind
    self.requestID = requestID
    self.spanName = spanName
    self.startedAt = Date()
    self.startedNanoseconds = now
  }

  public func mark(_ phase: String, attributes: [String: String] = [:]) {
    let now = DispatchTime.now().uptimeNanoseconds
    sink.recordTraceEvent(
      phase: phase,
      level: "metric",
      modelID: modelID,
      modelKind: modelKind,
      requestID: requestID.uuidString,
      monotonicNanoseconds: now,
      attributes: attributes
    )
  }

  public func finish(attributes: [String: String] = [:]) {
    let finishedNanoseconds = DispatchTime.now().uptimeNanoseconds
    sink.recordRequestSpan(
      name: spanName,
      modelID: modelID,
      modelKind: modelKind,
      requestID: requestID,
      startedAt: startedAt,
      durationMilliseconds: Double(finishedNanoseconds - startedNanoseconds) / 1_000_000,
      attributes: attributes
    )
  }
}
