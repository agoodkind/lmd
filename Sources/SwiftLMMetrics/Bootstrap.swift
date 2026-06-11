//
//  Bootstrap.swift
//  SwiftLMMetrics
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-06-06.
//  Copyright © 2026, all rights reserved.
//
//  Installs the metrics plane once at process start, beside AppLogger.bootstrap.
//  The in-process SnapshotSink is always wired so the JSON routes, the broker
//  merge, and the perf TUI tab work with no external infra. An OTLP export arm
//  (built by SwiftLMMetricsOTel behind an env gate) joins the same
//  MultiplexMetricsHandler when present.
//

import CoreMetrics
import Foundation
import Metrics

/// Namespace for the metrics plane, mirroring AppLogger.
public enum SwiftLMMetrics {
  /// The process-wide snapshot sink. Read by the metrics and traces routes, the
  /// broker merge, and the perf TUI tab. Always the shared instance, so direct
  /// reads and swift-metrics emissions land in the same store.
  public static var sink: SnapshotSink { SnapshotSink.shared }

  private static let bootstrapLock = NSLock()
  nonisolated(unsafe) private static var didBootstrap = false

  /// Install the metrics plane. Configures the sink's source identity, then
  /// bootstraps swift-metrics with the sink multiplexed alongside any export
  /// arms (for example the OTLP factory from SwiftLMMetricsOTel).
  ///
  /// Idempotent: MetricsSystem.bootstrap may run only once per process, so a
  /// repeat call reconfigures the source identity but does not re-bootstrap.
  /// Call installExportIfEnabled once and pass its factory before this runs,
  /// since the multiplex is fixed at the first bootstrap.
  public static func bootstrap(
    process: String,
    sourceID: String,
    modelID: String? = nil,
    modelKind: String? = nil,
    extraFactories: [MetricsFactory] = []
  ) {
    sink.configure(
      source: MetricsSource(
        sourceID: sourceID,
        process: process,
        modelID: modelID,
        modelKind: modelKind
      ))
    bootstrapLock.lock()
    defer { bootstrapLock.unlock() }
    guard !didBootstrap else { return }
    didBootstrap = true
    let factories: [MetricsFactory] = [sink] + extraFactories
    MetricsSystem.bootstrap(MultiplexMetricsHandler(factories: factories))
  }

  // MARK: - Typed emit gateway
  //
  // These let other targets emit metrics without importing swift-metrics
  // directly. They are thin wrappers over the swift-metrics facade, so the
  // values fan out through the multiplex to the SnapshotSink and any export arm.

  /// Set a gauge's current value.
  public static func setGauge(_ name: String, _ value: Double, labels: [(String, String)] = []) {
    Gauge(label: name, dimensions: labels).record(value)
  }

  /// Increment a counter by one.
  public static func incrementCounter(_ name: String, labels: [(String, String)] = []) {
    Counter(label: name, dimensions: labels).increment()
  }

  /// Add to a counter by a non-negative amount (for batch increments such as
  /// token counts).
  public static func addCounter(_ name: String, _ amount: Int, labels: [(String, String)] = []) {
    Counter(label: name, dimensions: labels).increment(by: Int64(max(0, amount)))
  }

  /// Record a duration observation (seconds) into a histogram.
  public static func observeSeconds(
    _ name: String, _ seconds: Double, labels: [(String, String)] = []
  ) {
    let nanoseconds = max(0, seconds) * 1_000_000_000
    Timer(label: name, dimensions: labels).recordNanoseconds(Int64(nanoseconds))
  }

  /// Record a unitless value (a ratio, a rate) into a histogram.
  public static func observeValue(
    _ name: String, _ value: Double, labels: [(String, String)] = []
  ) {
    Recorder(label: name, dimensions: labels, aggregate: true).record(value)
  }
}
