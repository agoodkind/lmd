//
//  SnapshotSink.swift
//  SwiftLMMetrics
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-06-06.
//  Copyright © 2026, all rights reserved.
//
//  Lock-protected process-local sink for counters, gauges, durations, and
//  request-correlated trace spans.
//

import Foundation

private struct MetricKey: Hashable {
  let name: String
  let labelsKey: String
  let labels: [String: String]

  init(name: String, labels: [String: String]) {
    self.name = name
    self.labels = labels
    self.labelsKey = labels.sorted { $0.key < $1.key }
      .map { "\($0.key)=\($0.value)" }
      .joined(separator: "\u{1f}")
  }

  static func == (lhs: MetricKey, rhs: MetricKey) -> Bool {
    lhs.name == rhs.name && lhs.labelsKey == rhs.labelsKey
  }

  func hash(into hasher: inout Hasher) {
    hasher.combine(name)
    hasher.combine(labelsKey)
  }
}

private struct HistogramAccumulator: Sendable {
  var count = 0
  var sum = 0.0
  var min = Double.greatestFiniteMagnitude
  var max = 0.0
  var last = 0.0

  mutating func record(_ value: Double) {
    count += 1
    sum += value
    min = Swift.min(min, value)
    max = Swift.max(max, value)
    last = value
  }
}

private struct LastPhase {
  let phase: String
  let monotonicNanoseconds: UInt64
}

public final class SnapshotSink: @unchecked Sendable {
  public static let shared = SnapshotSink()

  private let lock = NSLock()
  private var source = MetricsSource(sourceID: "unconfigured", process: "unknown")
  private var counters: [MetricKey: Double] = [:]
  private var gauges: [MetricKey: Double] = [:]
  private var histograms: [MetricKey: HistogramAccumulator] = [:]
  private var traces = TraceRingBuffer()
  private var lastRequestPhase: [String: LastPhase] = [:]

  public init() {}

  public func configure(source: MetricsSource) {
    lock.lock()
    self.source = source
    lock.unlock()
  }

  public func incrementCounter(
    name: String,
    by value: Double = 1.0,
    labels: [String: String] = [:]
  ) {
    lock.lock()
    incrementCounterLocked(name: name, by: value, labels: labels)
    lock.unlock()
  }

  public func setGauge(
    name: String,
    value: Double,
    labels: [String: String] = [:]
  ) {
    lock.lock()
    let key = MetricKey(name: name, labels: labelsWithSource(labels))
    gauges[key] = value
    lock.unlock()
  }

  public func recordDuration(
    name: String,
    seconds: Double,
    labels: [String: String] = [:]
  ) {
    lock.lock()
    recordDurationLocked(name: name, seconds: seconds, labels: labels)
    lock.unlock()
  }

  public func recordTraceEvent(
    phase: String,
    level: String,
    modelID: String,
    modelKind: String,
    requestID: String?,
    monotonicNanoseconds: UInt64,
    attributes: [String: String]
  ) {
    lock.lock()
    let span = MetricsTraceSpan(
      name: phase,
      sourceID: source.sourceID,
      modelID: modelID,
      modelKind: modelKind,
      requestID: requestID,
      startedAt: Date(),
      durationMilliseconds: 0,
      attributes: attributes.merging(["level": level]) { current, _ in current }
    )
    traces.append(span)
    incrementCounterLocked(
      name: "lmd_backend_trace_events_total",
      by: 1,
      labels: [
        "model_id": modelID,
        "model_kind": modelKind,
        "phase": phase,
      ]
    )
    recordPhaseIntervalIfPossible(
      phase: phase,
      modelID: modelID,
      modelKind: modelKind,
      requestID: requestID,
      monotonicNanoseconds: monotonicNanoseconds
    )
    lock.unlock()
  }

  public func recordRequestSpan(
    name: String,
    modelID: String,
    modelKind: String,
    requestID: UUID,
    startedAt: Date,
    durationMilliseconds: Double,
    attributes: [String: String] = [:]
  ) {
    lock.lock()
    let span = MetricsTraceSpan(
      name: name,
      sourceID: source.sourceID,
      modelID: modelID,
      modelKind: modelKind,
      requestID: requestID.uuidString,
      startedAt: startedAt,
      durationMilliseconds: durationMilliseconds,
      attributes: attributes
    )
    traces.append(span)
    recordDurationLocked(
      name: "lmd_backend_request_duration_seconds",
      seconds: durationMilliseconds / 1_000,
      labels: [
        "model_id": modelID,
        "model_kind": modelKind,
        "span": name,
      ]
    )
    lock.unlock()
  }

  public func snapshot() -> MetricsSnapshot {
    lock.lock()
    let result = MetricsSnapshot(
      source: source,
      metrics: MetricsPayload(
        counters: counters.map { key, value in
          MetricCounter(name: key.name, value: value, labels: key.labels)
        }.sorted { $0.name < $1.name },
        gauges: gauges.map { key, value in
          MetricGauge(name: key.name, value: value, labels: key.labels)
        }.sorted { $0.name < $1.name },
        histograms: histograms.map { key, value in
          MetricHistogram(
            name: key.name,
            count: value.count,
            sum: value.sum,
            min: value.count == 0 ? 0 : value.min,
            max: value.max,
            last: value.last,
            labels: key.labels
          )
        }.sorted { $0.name < $1.name },
      ),
      traces: traces.snapshot()
    )
    lock.unlock()
    return result
  }

  public func encodedSnapshot() throws -> Data {
    try MetricsJSON.encoder.encode(snapshot())
  }

  private func labelsWithSource(_ labels: [String: String]) -> [String: String] {
    labels.merging(["source_id": source.sourceID]) { current, _ in current }
  }

  private func incrementCounterLocked(
    name: String,
    by value: Double,
    labels: [String: String]
  ) {
    let key = MetricKey(name: name, labels: labelsWithSource(labels))
    counters[key, default: 0] += value
  }

  private func recordDurationLocked(
    name: String,
    seconds: Double,
    labels: [String: String]
  ) {
    let key = MetricKey(name: name, labels: labelsWithSource(labels))
    var histogram = histograms[key] ?? HistogramAccumulator()
    histogram.record(seconds)
    histograms[key] = histogram
  }

  private func recordPhaseIntervalIfPossible(
    phase: String,
    modelID: String,
    modelKind: String,
    requestID: String?,
    monotonicNanoseconds: UInt64
  ) {
    guard phase.hasPrefix("request_"), let requestID else {
      return
    }
    let key = "\(source.sourceID)|\(modelID)|\(modelKind)|\(requestID)"
    if let previous = lastRequestPhase[key],
      monotonicNanoseconds >= previous.monotonicNanoseconds
    {
      let delta = monotonicNanoseconds - previous.monotonicNanoseconds
      recordDurationLocked(
        name: "lmd_backend_phase_duration_seconds",
        seconds: Double(delta) / 1_000_000_000,
        labels: [
          "model_id": modelID,
          "model_kind": modelKind,
          "phase": previous.phase,
        ]
      )
    }
    lastRequestPhase[key] = LastPhase(
      phase: phase,
      monotonicNanoseconds: monotonicNanoseconds
    )
    if phase == "request_pre_return" || phase == "request_post_generate" {
      lastRequestPhase.removeValue(forKey: key)
    }
  }
}
