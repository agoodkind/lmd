//
//  SnapshotSinkFactory.swift
//  SwiftLMMetrics
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-06-07.
//  Copyright © 2026, all rights reserved.
//
//  swift-metrics MetricsFactory conformance for SnapshotSink. Each factory
//  method mints a small handler holding the metric name, its dimensions as
//  labels, and a reference back to the sink. Counters accumulate, meters and
//  non-aggregating recorders act as last-value gauges, and timers and
//  aggregating recorders feed the per-series count/sum/min/max/last histogram.
//  The sink stamps source_id on every series, so handlers pass the swift-metrics
//  dimensions through as labels untouched.
//

import CoreMetrics
import Foundation

/// Flatten swift-metrics dimensions into the label dictionary the sink expects.
/// Later duplicate keys win, matching how the sink keys a series.
private func labelsFromDimensions(_ dimensions: [(String, String)]) -> [String: String] {
  var labels: [String: String] = [:]
  labels.reserveCapacity(dimensions.count)
  for (key, value) in dimensions {
    labels[key] = value
  }
  return labels
}

extension SnapshotSink: CoreMetrics.MetricsFactory {
  public func makeCounter(label: String, dimensions: [(String, String)]) -> CounterHandler {
    SnapshotCounter(sink: self, name: label, labels: labelsFromDimensions(dimensions))
  }

  public func makeMeter(label: String, dimensions: [(String, String)]) -> MeterHandler {
    SnapshotMeter(sink: self, name: label, labels: labelsFromDimensions(dimensions))
  }

  public func makeRecorder(
    label: String,
    dimensions: [(String, String)],
    aggregate: Bool
  ) -> RecorderHandler {
    // aggregate=true is a histogram (swift-metrics Recorder); aggregate=false is
    // a last-value gauge (swift-metrics Gauge). Route each to the right store.
    SnapshotRecorder(
      sink: self, name: label, labels: labelsFromDimensions(dimensions), aggregate: aggregate)
  }

  public func makeTimer(label: String, dimensions: [(String, String)]) -> TimerHandler {
    SnapshotTimer(sink: self, name: label, labels: labelsFromDimensions(dimensions))
  }

  // The handlers are valueless references into the shared store; there is no
  // per-handler resource to release, so destroys are no-ops.
  public func destroyCounter(_ handler: CounterHandler) {}
  public func destroyMeter(_ handler: MeterHandler) {}
  public func destroyRecorder(_ handler: RecorderHandler) {}
  public func destroyTimer(_ handler: TimerHandler) {}
}

private final class SnapshotCounter: CounterHandler, @unchecked Sendable {
  private let sink: SnapshotSink
  private let name: String
  private let labels: [String: String]

  init(sink: SnapshotSink, name: String, labels: [String: String]) {
    self.sink = sink
    self.name = name
    self.labels = labels
  }

  func increment(by amount: Int64) {
    sink.incrementCounter(name: name, by: Double(amount), labels: labels)
  }

  func reset() { sink.resetCounter(name: name, labels: labels) }
}

private final class SnapshotMeter: MeterHandler, @unchecked Sendable {
  private let sink: SnapshotSink
  private let name: String
  private let labels: [String: String]

  init(sink: SnapshotSink, name: String, labels: [String: String]) {
    self.sink = sink
    self.name = name
    self.labels = labels
  }

  func set(_ value: Int64) { sink.setGauge(name: name, value: Double(value), labels: labels) }
  func set(_ value: Double) { sink.setGauge(name: name, value: value, labels: labels) }
  func increment(by amount: Double) { sink.adjustGauge(name: name, by: amount, labels: labels) }
  func decrement(by amount: Double) { sink.adjustGauge(name: name, by: -amount, labels: labels) }
}

private final class SnapshotRecorder: RecorderHandler, @unchecked Sendable {
  private let sink: SnapshotSink
  private let name: String
  private let labels: [String: String]
  private let aggregate: Bool

  init(sink: SnapshotSink, name: String, labels: [String: String], aggregate: Bool) {
    self.sink = sink
    self.name = name
    self.labels = labels
    self.aggregate = aggregate
  }

  func record(_ value: Int64) { record(Double(value)) }
  func record(_ value: Double) {
    if aggregate {
      sink.recordDuration(name: name, seconds: value, labels: labels)
    } else {
      sink.setGauge(name: name, value: value, labels: labels)
    }
  }
}

private final class SnapshotTimer: TimerHandler, @unchecked Sendable {
  private let sink: SnapshotSink
  private let name: String
  private let labels: [String: String]

  init(sink: SnapshotSink, name: String, labels: [String: String]) {
    self.sink = sink
    self.name = name
    self.labels = labels
  }

  func recordNanoseconds(_ duration: Int64) {
    sink.recordDuration(name: name, seconds: Double(duration) / 1_000_000_000, labels: labels)
  }
}
