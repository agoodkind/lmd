//
//  SnapshotSinkFactoryTests.swift
//  SwiftLMMetricsTests
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-06-07.
//  Copyright © 2026, all rights reserved.
//
//  Exercises the swift-metrics MetricsFactory conformance and the JSON shape
//  the broker merge, the metrics route, and the perf tab depend on. The tests
//  drive a fresh SnapshotSink directly instead of MetricsSystem.bootstrap,
//  since the global metrics system can be bootstrapped only once per process.
//

import CoreMetrics
import Foundation
import XCTest

@testable import SwiftLMMetrics

final class SnapshotSinkFactoryTests: XCTestCase {
  private func configuredSink(sourceID: String = "test-source") -> SnapshotSink {
    let sink = SnapshotSink()
    sink.configure(source: MetricsSource(sourceID: sourceID, process: "test"))
    return sink
  }

  private func counter(_ snapshot: MetricsSnapshot, named name: String) -> MetricCounter? {
    snapshot.metrics.counters.first { $0.name == name }
  }

  private func gauge(_ snapshot: MetricsSnapshot, named name: String) -> MetricGauge? {
    snapshot.metrics.gauges.first { $0.name == name }
  }

  private func histogram(_ snapshot: MetricsSnapshot, named name: String) -> MetricHistogram? {
    snapshot.metrics.histograms.first { $0.name == name }
  }

  func testCounterFactoryAccumulates() {
    let sink = configuredSink()
    let handler = sink.makeCounter(
      label: "lmd_requests_total", dimensions: [("model_kind", "chat")])
    handler.increment(by: 3)
    handler.increment(by: 4)

    let found = counter(sink.snapshot(), named: "lmd_requests_total")
    XCTAssertEqual(found?.value, 7)
    XCTAssertEqual(found?.labels["model_kind"], "chat")
  }

  func testCounterResetZeroesSeries() {
    let sink = configuredSink()
    let handler = sink.makeCounter(label: "c", dimensions: [])
    handler.increment(by: 5)
    handler.reset()

    XCTAssertEqual(counter(sink.snapshot(), named: "c")?.value, 0)
  }

  func testMeterFactoryHoldsLastValue() {
    let sink = configuredSink()
    let handler = sink.makeMeter(label: "lmd_broker_loaded_models", dimensions: [])
    handler.set(2.0)
    handler.set(5.0)

    XCTAssertEqual(gauge(sink.snapshot(), named: "lmd_broker_loaded_models")?.value, 5)
  }

  func testMeterIncrementAndDecrementAdjustGauge() {
    let sink = configuredSink()
    let handler = sink.makeMeter(label: "g", dimensions: [])
    handler.increment(by: 4)
    handler.decrement(by: 1.5)

    XCTAssertEqual(gauge(sink.snapshot(), named: "g")?.value, 2.5)
  }

  func testNonAggregatingRecorderActsAsGauge() {
    let sink = configuredSink()
    let handler = sink.makeRecorder(label: "r", dimensions: [], aggregate: false)
    handler.record(9.0)

    XCTAssertEqual(gauge(sink.snapshot(), named: "r")?.value, 9)
    XCTAssertNil(histogram(sink.snapshot(), named: "r"))
  }

  func testTimerFactoryFeedsCountSumMinMax() throws {
    let sink = configuredSink()
    let handler = sink.makeTimer(label: "lmd_chat_inter_token_seconds", dimensions: [])
    handler.recordNanoseconds(1_000_000_000)  // 1.0s
    handler.recordNanoseconds(3_000_000_000)  // 3.0s

    let found = try XCTUnwrap(histogram(sink.snapshot(), named: "lmd_chat_inter_token_seconds"))
    XCTAssertEqual(found.count, 2)
    XCTAssertEqual(found.sum, 4.0, accuracy: 1e-9)
    XCTAssertEqual(found.min, 1.0, accuracy: 1e-9)
    XCTAssertEqual(found.max, 3.0, accuracy: 1e-9)
    XCTAssertEqual(found.last, 3.0, accuracy: 1e-9)
  }

  func testSourceIdStampedOnEverySeries() {
    let sink = configuredSink(sourceID: "host:chat:/models/x")
    sink.makeCounter(label: "c", dimensions: []).increment(by: 1)
    sink.makeMeter(label: "g", dimensions: []).set(1.0)
    sink.makeTimer(label: "t", dimensions: []).recordNanoseconds(1_000)

    let snapshot = sink.snapshot()
    XCTAssertEqual(counter(snapshot, named: "c")?.labels["source_id"], "host:chat:/models/x")
    XCTAssertEqual(gauge(snapshot, named: "g")?.labels["source_id"], "host:chat:/models/x")
    XCTAssertEqual(histogram(snapshot, named: "t")?.labels["source_id"], "host:chat:/models/x")
  }

  func testMultiplexFansOutToEverySink() {
    let first = configuredSink(sourceID: "a")
    let second = configuredSink(sourceID: "b")
    let multiplex = MultiplexMetricsHandler(factories: [first, second])
    multiplex.makeCounter(label: "lmd_tokens_total", dimensions: []).increment(by: 11)

    XCTAssertEqual(counter(first.snapshot(), named: "lmd_tokens_total")?.value, 11)
    XCTAssertEqual(counter(second.snapshot(), named: "lmd_tokens_total")?.value, 11)
  }

  func testMergeRoundTripsThroughPrometheus() {
    let sink = configuredSink(sourceID: "broker")
    sink.makeMeter(label: "lmd_broker_loaded_models", dimensions: []).set(2.0)
    sink.makeCounter(label: "lmd_tokens_total", dimensions: [("model_kind", "chat")])
      .increment(by: 5)

    let merged = MetricsJSON.merge([sink.snapshot()])
    XCTAssertEqual(merged.sources.count, 1)
    XCTAssertEqual(merged.sources.first?.sourceID, "broker")

    let exposition = PrometheusExposition.render(merged)
    XCTAssertTrue(exposition.contains("lmd_broker_loaded_models"))
    XCTAssertTrue(exposition.contains("lmd_tokens_total"))
  }
}
