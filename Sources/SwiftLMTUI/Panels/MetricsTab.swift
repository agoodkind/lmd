//
//  MetricsTab.swift
//  SwiftLMTUI
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-06-07.
//  Copyright © 2026, all rights reserved.
//
//  Live perf view: which model hosts are running, their GPU/memory gauges,
//  where time is going per phase (from the duration histograms), and the most
//  recent spans. The host pushes a metrics snapshot fetched over XPC; this tab
//  decodes it, so it stays free of the SwiftLMMetrics module. Answers "the GPU
//  is busy, what exactly is running" without standing up Grafana.
//

import AppLogger
import Foundation

private let log = AppLogger.logger(category: "MetricsTab")

// MARK: - Wire shape (subset of the broker metrics snapshot)

/// Decoded subset of the broker metrics snapshot JSON. Only the fields the tab
/// renders are modeled; unknown keys are ignored.
struct MetricsPayload: Decodable, Sendable {
  let generatedAt: String?
  let sources: [Source]
  let metrics: Plane
  let traces: [Span]

  enum CodingKeys: String, CodingKey {
    case generatedAt = "generated_at"
    case sources
    case metrics
    case traces
  }

  struct Source: Decodable, Sendable {
    let sourceID: String
    let process: String
    let pid: Int

    enum CodingKeys: String, CodingKey {
      case sourceID = "source_id"
      case process
      case pid
    }
  }

  struct Plane: Decodable, Sendable {
    let counters: [Sample]
    let gauges: [Sample]
    let histograms: [Histogram]
  }

  struct Labels: Decodable, Sendable {
    let modelID: String?
    let modelKind: String?
    let phase: String?
    let sourceID: String?

    enum CodingKeys: String, CodingKey {
      case modelID = "model_id"
      case modelKind = "model_kind"
      case phase
      case sourceID = "source_id"
    }
  }

  struct Sample: Decodable, Sendable {
    let name: String
    let value: Double
    let labels: Labels
  }

  struct Histogram: Decodable, Sendable {
    let name: String
    let count: Int
    let sum: Double
    let labels: Labels
  }

  struct Span: Decodable, Sendable {
    let name: String
    let modelID: String
    let modelKind: String
    let sourceID: String
    let durationMS: Int

    enum CodingKeys: String, CodingKey {
      case name
      case modelID = "model_id"
      case modelKind = "model_kind"
      case sourceID = "source_id"
      case durationMS = "duration_ms"
    }
  }
}

// MARK: - MetricsTab

public final class MetricsTab: Tab {
  public let label = "perf"
  public let title = "perf"

  private var payload: MetricsPayload?
  private var statusLine: String = "(waiting for broker metrics …)"
  private var scrollOffset = 0

  public init() {}

  // MARK: - Mutation API (called by the host)

  /// Replace the rendered snapshot from a fresh metrics-snapshot body.
  public func update(from data: Data) {
    do {
      payload = try JSONDecoder().decode(MetricsPayload.self, from: data)
      statusLine = ""
    } catch {
      statusLine = "decode failed: \(error)"
      log.error("perf.decode_failed err=\(String(describing: error), privacy: .public)")
    }
  }

  /// Note that the broker was unreachable this cycle (keeps the last snapshot).
  public func markUnavailable() {
    if payload == nil {
      statusLine = "(broker metrics unreachable)"
    }
  }

  // MARK: - Render

  public func render(into buffer: ScreenBuffer, contentRows rows: ClosedRange<Int>) {
    let lines = composeLines()
    let visible = rows.upperBound - rows.lowerBound + 1
    let maxOffset = max(0, lines.count - visible)
    let offset = min(scrollOffset, maxOffset)
    var row = rows.lowerBound
    let end = min(lines.count, offset + visible)
    var index = offset
    while index < end {
      buffer.put(row: row, lines[index])
      row += 1
      index += 1
    }
  }

  private func composeLines() -> [String] {
    var lines: [String] = []
    let generated = payload?.generatedAt ?? ""
    lines.append(
      "\(Theme.head)PERF\(Ansi.reset)  "
        + "\(Theme.dim)\(generated)  j/k scroll · live over XPC\(Ansi.reset)")
    if !statusLine.isEmpty {
      lines.append("\(Theme.warn)\(statusLine)\(Ansi.reset)")
    }
    guard let payload else { return lines }
    lines.append("")
    appendHosts(payload, into: &lines)
    appendGauges(payload, into: &lines)
    appendTimeByPhase(payload, into: &lines)
    appendRecentSpans(payload, into: &lines)
    return lines
  }

  private func appendHosts(_ payload: MetricsPayload, into lines: inout [String]) {
    lines.append(
      "\(Theme.label)HOSTS\(Ansi.reset) \(Theme.dim)(\(payload.sources.count))\(Ansi.reset)")
    if payload.sources.isEmpty {
      lines.append("  \(Theme.dim)broker only, no model hosts resident\(Ansi.reset)")
    }
    for source in payload.sources.sorted(by: { $0.process < $1.process }) {
      lines.append(
        "  \(Theme.text)\(Self.pad(source.process, 18))\(Ansi.reset)"
          + "\(Theme.dim)pid \(Self.pad(String(source.pid), 7))\(Ansi.reset)"
          + "\(Theme.dim)\(source.sourceID)\(Ansi.reset)")
    }
    lines.append("")
  }

  private func appendGauges(_ payload: MetricsPayload, into lines: inout [String]) {
    let interesting = payload.metrics.gauges.filter {
      $0.name.contains("gpu") || $0.name.contains("mem") || $0.name.contains("inflight")
        || $0.name.contains("loaded")
    }
    guard !interesting.isEmpty else { return }
    lines.append("\(Theme.label)GPU / MEMORY\(Ansi.reset)")
    for gauge in interesting.sorted(by: { $0.name < $1.name }) {
      let shown =
        gauge.name.contains("bytes")
        ? Self.bytes(Int64(gauge.value)) : String(Int(gauge.value))
      let src = gauge.labels.sourceID.map { " \(Theme.dim)[\($0)]\(Ansi.reset)" } ?? ""
      lines.append(
        "  \(Theme.text)\(Self.pad(Self.short(gauge.name), 26))\(Ansi.reset)"
          + "\(Theme.accent)\(shown)\(Ansi.reset)\(src)")
    }
    lines.append("")
  }

  private func appendTimeByPhase(_ payload: MetricsPayload, into lines: inout [String]) {
    var totalSum: [String: Double] = [:]
    var totalCount: [String: Int] = [:]
    for histogram in payload.metrics.histograms {
      let key = histogram.labels.phase ?? Self.short(histogram.name)
      totalSum[key, default: 0] += histogram.sum
      totalCount[key, default: 0] += histogram.count
    }
    guard !totalSum.isEmpty else { return }
    let grandTotal = totalSum.values.reduce(0, +)
    lines.append(
      "\(Theme.label)TIME BY PHASE\(Ansi.reset) \(Theme.dim)(avg ms · n · share)\(Ansi.reset)")
    let ordered = totalSum.sorted { $0.value > $1.value }
    for (phase, sum) in ordered {
      let count = totalCount[phase] ?? 0
      let avgMS = count > 0 ? (sum / Double(count)) * 1000.0 : 0
      let share = grandTotal > 0 ? sum / grandTotal : 0
      let bar = Self.bar(share, width: 16)
      lines.append(
        "  \(Theme.text)\(Self.pad(phase, 18))\(Ansi.reset)"
          + "\(Theme.accent)\(Self.pad(String(format: "%.1f", avgMS), 8))\(Ansi.reset)"
          + "\(Theme.dim)\(Self.pad("n=\(count)", 9))\(Ansi.reset)"
          + "\(Theme.ok)\(bar)\(Ansi.reset) \(Theme.dim)\(Int(share * 100))%\(Ansi.reset)")
    }
    lines.append("")
  }

  private func appendRecentSpans(_ payload: MetricsPayload, into lines: inout [String]) {
    lines.append(
      "\(Theme.label)RECENT SPANS\(Ansi.reset) "
        + "\(Theme.dim)(\(payload.traces.count) buffered, newest first)\(Ansi.reset)")
    for span in payload.traces.suffix(200).reversed() {
      let model = Self.modelName(span.modelID)
      lines.append(
        "  \(Theme.accent)\(Self.padLeft("\(span.durationMS)ms", 8))\(Ansi.reset)  "
          + "\(Theme.text)\(Self.pad(Self.short(span.name), 24))\(Ansi.reset)"
          + "\(Theme.label)\(Self.pad(model, 26))\(Ansi.reset)"
          + "\(Theme.dim)\(span.modelKind)\(Ansi.reset)")
    }
  }

  // MARK: - Input

  public func handle(_ input: TabInput) -> TabAction {
    switch input {
    case .key(.scrollUp):
      scrollOffset = max(0, scrollOffset - 1)
      return .none
    case .key(.scrollDown):
      scrollOffset += 1
      return .none
    case .key(.top):
      scrollOffset = 0
      return .none
    case .key(.quit):
      return .quit
    case .mouseWheel(let event):
      scrollOffset = event.isWheelUp ? max(0, scrollOffset - 3) : scrollOffset + 3
      return .none
    default:
      return .none
    }
  }

  // MARK: - Formatting helpers

  /// Strip the common `lmd_` metric prefix for compact display.
  private static func short(_ name: String) -> String {
    name.hasPrefix("lmd_") ? String(name.dropFirst(4)) : name
  }

  /// Last two path components of a model id (publisher/model), or the tail.
  private static func modelName(_ id: String) -> String {
    let parts = id.split(separator: "/")
    if parts.count >= 2 {
      return parts.suffix(2).joined(separator: "/")
    }
    return String(id.suffix(26))
  }

  private static func bytes(_ value: Int64) -> String {
    let gib = 1024.0 * 1024.0 * 1024.0
    let mib = 1024.0 * 1024.0
    let v = Double(value)
    if v >= gib {
      return String(format: "%.2f GiB", v / gib)
    }
    if v >= mib {
      return String(format: "%.0f MiB", v / mib)
    }
    return "\(value) B"
  }

  private static func bar(_ share: Double, width: Int) -> String {
    let filled = max(0, min(width, Int((share * Double(width)).rounded())))
    return String(repeating: "▆", count: filled) + String(repeating: " ", count: width - filled)
  }

  private static func pad(_ s: String, _ width: Int) -> String {
    if s.count >= width { return String(s.prefix(width)) + " " }
    return s + String(repeating: " ", count: width - s.count)
  }

  private static func padLeft(_ s: String, _ width: Int) -> String {
    if s.count >= width { return String(s.prefix(width)) }
    return String(repeating: " ", count: width - s.count) + s
  }
}
