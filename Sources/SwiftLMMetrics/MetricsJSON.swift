//
//  MetricsJSON.swift
//  SwiftLMMetrics
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-06-06.
//  Copyright © 2026, all rights reserved.
//
//  JSON assembly for local and merged metrics snapshots.
//

import Foundation

public enum MetricsJSON {
  public static let encoder: JSONEncoder = {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys]
    return encoder
  }()

  public static let decoder: JSONDecoder = {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return decoder
  }()

  public static func decodeSnapshot(_ data: Data) throws -> MetricsSnapshot {
    try decoder.decode(MetricsSnapshot.self, from: data)
  }

  public static func merge(_ snapshots: [MetricsSnapshot]) -> MergedMetricsSnapshot {
    var counters: [MetricCounter] = []
    var gauges: [MetricGauge] = []
    var histograms: [MetricHistogram] = []
    var traces: [MetricsTraceSpan] = []
    var sources: [MetricsSource] = []
    for snapshot in snapshots {
      sources.append(snapshot.source)
      counters.append(contentsOf: snapshot.metrics.counters)
      gauges.append(contentsOf: snapshot.metrics.gauges)
      histograms.append(contentsOf: snapshot.metrics.histograms)
      traces.append(contentsOf: snapshot.traces)
    }
    return MergedMetricsSnapshot(
      sources: sources.sorted { $0.sourceID < $1.sourceID },
      metrics: MetricsPayload(
        counters: counters.sorted { $0.name < $1.name },
        gauges: gauges.sorted { $0.name < $1.name },
        histograms: histograms.sorted { $0.name < $1.name }
      ),
      traces: traces.sorted { $0.startedAt < $1.startedAt }
    )
  }

  public static func tracesPayload(from merged: MergedMetricsSnapshot) throws -> Data {
    let payload = MetricsTracesResponse(
      schemaVersion: merged.schemaVersion,
      generatedAt: merged.generatedAt,
      sources: merged.sources,
      traces: merged.traces
    )
    return try encoder.encode(payload)
  }
}

private struct MetricsTracesResponse: Codable {
  let schemaVersion: Int
  let generatedAt: Date
  let sources: [MetricsSource]
  let traces: [MetricsTraceSpan]

  enum CodingKeys: String, CodingKey {
    case schemaVersion = "schema_version"
    case generatedAt = "generated_at"
    case sources
    case traces
  }
}
