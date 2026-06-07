//
//  MetricsModels.swift
//  SwiftLMMetrics
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-06-06.
//  Copyright © 2026, all rights reserved.
//
//  Codable metrics and trace payloads shared by model hosts and the broker.
//

import Foundation

public let swiftLMMetricsSchemaVersion = 1

public struct MetricsSource: Codable, Equatable, Sendable {
  public let sourceID: String
  public let process: String
  public let modelID: String?
  public let modelKind: String?
  public let pid: Int32
  public let startedAt: Date

  public init(
    sourceID: String,
    process: String,
    modelID: String? = nil,
    modelKind: String? = nil,
    pid: Int32 = ProcessInfo.processInfo.processIdentifier,
    startedAt: Date = Date()
  ) {
    self.sourceID = sourceID
    self.process = process
    self.modelID = modelID
    self.modelKind = modelKind
    self.pid = pid
    self.startedAt = startedAt
  }

  enum CodingKeys: String, CodingKey {
    case sourceID = "source_id"
    case process
    case modelID = "model_id"
    case modelKind = "model_kind"
    case pid
    case startedAt = "started_at"
  }
}

public struct MetricCounter: Codable, Equatable, Sendable {
  public let name: String
  public let value: Double
  public let labels: [String: String]
}

public struct MetricGauge: Codable, Equatable, Sendable {
  public let name: String
  public let value: Double
  public let labels: [String: String]
}

public struct MetricHistogram: Codable, Equatable, Sendable {
  public let name: String
  public let count: Int
  public let sum: Double
  public let min: Double
  public let max: Double
  public let last: Double
  public let labels: [String: String]
}

public struct MetricsPayload: Codable, Equatable, Sendable {
  public let counters: [MetricCounter]
  public let gauges: [MetricGauge]
  public let histograms: [MetricHistogram]

  public init(
    counters: [MetricCounter],
    gauges: [MetricGauge],
    histograms: [MetricHistogram]
  ) {
    self.counters = counters
    self.gauges = gauges
    self.histograms = histograms
  }
}

public struct MetricsTraceSpan: Codable, Equatable, Sendable {
  public let spanID: UUID
  public let parentSpanID: UUID?
  public let name: String
  public let sourceID: String
  public let modelID: String?
  public let modelKind: String?
  public let requestID: String?
  public let startedAt: Date
  public let durationMilliseconds: Double
  public let attributes: [String: String]

  public init(
    spanID: UUID = UUID(),
    parentSpanID: UUID? = nil,
    name: String,
    sourceID: String,
    modelID: String?,
    modelKind: String?,
    requestID: String?,
    startedAt: Date,
    durationMilliseconds: Double,
    attributes: [String: String] = [:]
  ) {
    self.spanID = spanID
    self.parentSpanID = parentSpanID
    self.name = name
    self.sourceID = sourceID
    self.modelID = modelID
    self.modelKind = modelKind
    self.requestID = requestID
    self.startedAt = startedAt
    self.durationMilliseconds = durationMilliseconds
    self.attributes = attributes
  }

  enum CodingKeys: String, CodingKey {
    case spanID = "span_id"
    case parentSpanID = "parent_span_id"
    case name
    case sourceID = "source_id"
    case modelID = "model_id"
    case modelKind = "model_kind"
    case requestID = "request_id"
    case startedAt = "started_at"
    case durationMilliseconds = "duration_ms"
    case attributes
  }
}

public struct MetricsSnapshot: Codable, Equatable, Sendable {
  public let schemaVersion: Int
  public let generatedAt: Date
  public let source: MetricsSource
  public let metrics: MetricsPayload
  public let traces: [MetricsTraceSpan]

  public init(
    schemaVersion: Int = swiftLMMetricsSchemaVersion,
    generatedAt: Date = Date(),
    source: MetricsSource,
    metrics: MetricsPayload,
    traces: [MetricsTraceSpan]
  ) {
    self.schemaVersion = schemaVersion
    self.generatedAt = generatedAt
    self.source = source
    self.metrics = metrics
    self.traces = traces
  }

  enum CodingKeys: String, CodingKey {
    case schemaVersion = "schema_version"
    case generatedAt = "generated_at"
    case source
    case metrics
    case traces
  }
}

public struct MergedMetricsSnapshot: Codable, Equatable, Sendable {
  public let schemaVersion: Int
  public let generatedAt: Date
  public let sources: [MetricsSource]
  public let metrics: MetricsPayload
  public let traces: [MetricsTraceSpan]

  public init(
    schemaVersion: Int = swiftLMMetricsSchemaVersion,
    generatedAt: Date = Date(),
    sources: [MetricsSource],
    metrics: MetricsPayload,
    traces: [MetricsTraceSpan]
  ) {
    self.schemaVersion = schemaVersion
    self.generatedAt = generatedAt
    self.sources = sources
    self.metrics = metrics
    self.traces = traces
  }

  enum CodingKeys: String, CodingKey {
    case schemaVersion = "schema_version"
    case generatedAt = "generated_at"
    case sources
    case metrics
    case traces
  }
}
