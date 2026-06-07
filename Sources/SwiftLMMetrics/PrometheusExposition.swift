//
//  PrometheusExposition.swift
//  SwiftLMMetrics
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-06-06.
//  Copyright © 2026, all rights reserved.
//
//  Text exposition for the env-gated /metrics endpoint.
//

import Foundation

public enum PrometheusExposition {
  private static let quote = #"""#

  public static func render(_ snapshot: MergedMetricsSnapshot) -> String {
    var lines: [String] = []
    for counter in snapshot.metrics.counters {
      lines.append("# TYPE \(counter.name) counter")
      lines.append("\(counter.name)\(labels(counter.labels)) \(counter.value)")
    }
    for gauge in snapshot.metrics.gauges {
      lines.append("# TYPE \(gauge.name) gauge")
      lines.append("\(gauge.name)\(labels(gauge.labels)) \(gauge.value)")
    }
    for histogram in snapshot.metrics.histograms {
      lines.append("# TYPE \(histogram.name) summary")
      lines.append("\(histogram.name)_count\(labels(histogram.labels)) \(histogram.count)")
      lines.append("\(histogram.name)_sum\(labels(histogram.labels)) \(histogram.sum)")
      lines.append("\(histogram.name)_min\(labels(histogram.labels)) \(histogram.min)")
      lines.append("\(histogram.name)_max\(labels(histogram.labels)) \(histogram.max)")
      lines.append("\(histogram.name)_last\(labels(histogram.labels)) \(histogram.last)")
    }
    lines.append("")
    return lines.joined(separator: "\n")
  }

  private static func labels(_ labels: [String: String]) -> String {
    guard !labels.isEmpty else {
      return ""
    }
    let rendered = labels.sorted { $0.key < $1.key }
      .map { label in
        label.key + "=" + Self.quote + escape(label.value) + Self.quote
      }
      .joined(separator: ",")
    return "{\(rendered)}"
  }

  private static func escape(_ value: String) -> String {
    let slash = "\\"

    return value
      .replacingOccurrences(of: slash, with: slash + slash)
      .replacingOccurrences(of: Self.quote, with: slash + Self.quote)
      .replacingOccurrences(of: "\n", with: slash + "n")
  }
}
