//
//  EmbedBenchRunner.swift
//  lmd-bench
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-06-11.
//  Copyright © 2026, all rights reserved.
//

import AppLogger
import Foundation

private let log = AppLogger.logger(category: "EmbedBenchRunner")

// MARK: - EmbedBenchRunConfiguration

/// Everything one bench run needs, bundled so the entry point stays inside
/// the repo's parameter-count gate and call sites read as configuration.
public struct EmbedBenchRunConfiguration: Sendable {
  public let baseURL: String
  public let model: String
  public let corpus: [String]
  public let rowsPerRequest: Int
  public let requests: Int
  public let jsonOutput: Bool

  public init(
    baseURL: String,
    model: String,
    corpus: [String],
    rowsPerRequest: Int,
    requests: Int,
    jsonOutput: Bool
  ) {
    self.baseURL = baseURL
    self.model = model
    self.corpus = corpus
    self.rowsPerRequest = rowsPerRequest
    self.requests = requests
    self.jsonOutput = jsonOutput
  }
}

// MARK: - EmbedBenchRunner

public enum EmbedBenchRunner {
  private static let embeddingsPath = "/v1/embeddings"
  private static let metricsPath = "/swiftlmd/metrics"
  private static let contentTypeHeader = "Content-Type"
  private static let jsonContentType = "application/json"
  private static let httpOKStatusCode = 200
  private static let nanosecondsPerSecond = 1_000_000_000.0
  private static let bytesPerEstimatedToken = 4
  private static let metricNamePrefix = "lmd_embed_"
  private static let tableNameColumnWidth = 42

  public static func run(_ configuration: EmbedBenchRunConfiguration) async throws {
    guard configuration.rowsPerRequest > 0 else {
      throw EmbedBenchRunnerError.invalidRowsPerRequest(configuration.rowsPerRequest)
    }
    guard configuration.requests >= 0 else {
      throw EmbedBenchRunnerError.invalidRequestCount(configuration.requests)
    }
    guard !configuration.corpus.isEmpty || configuration.requests == 0 else {
      throw EmbedBenchRunnerError.emptyCorpus
    }

    log.notice(
      "embed_bench.started model=\(configuration.model, privacy: .public) requests=\(configuration.requests, privacy: .public) rows_per_request=\(configuration.rowsPerRequest, privacy: .public)"
    )

    let embeddingsURL = try endpoint(baseURL: configuration.baseURL, path: embeddingsPath)
    var batches: [EmbedBenchStats.BatchSample] = []
    batches.reserveCapacity(configuration.requests)
    var corpusIndex = 0

    for requestIndex in 0..<configuration.requests {
      let inputs = nextBatch(
        corpus: configuration.corpus,
        rowsPerRequest: configuration.rowsPerRequest,
        corpusIndex: &corpusIndex
      )
      let estimatedTokens = estimateTokens(inputs)
      let seconds = try await postEmbeddingRequest(
        url: embeddingsURL,
        model: configuration.model,
        inputs: inputs
      )
      batches.append(
        EmbedBenchStats.BatchSample(
          rows: inputs.count,
          estimatedTokens: estimatedTokens,
          seconds: seconds
        )
      )
      log.notice(
        "embed_bench.request_completed index=\(requestIndex, privacy: .public) rows=\(inputs.count, privacy: .public) seconds=\(seconds, privacy: .public)"
      )
    }

    let report = EmbedBenchStats.makeReport(batches: batches)
    let serverMetrics = try await fetchServerMetrics(baseURL: configuration.baseURL)
    let summary = EmbedBenchSummary(
      baseURL: configuration.baseURL,
      model: configuration.model,
      requests: configuration.requests,
      rowsPerRequest: configuration.rowsPerRequest,
      clientReport: report,
      batches: batches,
      serverMetrics: serverMetrics
    )

    if configuration.jsonOutput {
      try printJSON(summary)
    } else {
      printHuman(summary)
    }

    log.notice("embed_bench.completed rows=\(report.totalRows, privacy: .public)")
  }

  private static func endpoint(baseURL: String, path: String) throws -> URL {
    var trimmedBaseURL = baseURL
    while trimmedBaseURL.hasSuffix("/") {
      trimmedBaseURL.removeLast()
    }
    guard let url = URL(string: trimmedBaseURL + path) else {
      throw EmbedBenchRunnerError.invalidBaseURL(baseURL)
    }
    return url
  }

  private static func nextBatch(
    corpus: [String],
    rowsPerRequest: Int,
    corpusIndex: inout Int
  ) -> [String] {
    var inputs: [String] = []
    inputs.reserveCapacity(rowsPerRequest)

    for _ in 0..<rowsPerRequest {
      inputs.append(corpus[corpusIndex])
      corpusIndex += 1
      if corpusIndex == corpus.count {
        corpusIndex = 0
      }
    }

    return inputs
  }

  private static func estimateTokens(_ inputs: [String]) -> Int {
    var total = 0
    for input in inputs {
      total += (input.utf8.count + bytesPerEstimatedToken - 1) / bytesPerEstimatedToken
    }
    return total
  }

  private static func postEmbeddingRequest(
    url: URL,
    model: String,
    inputs: [String]
  ) async throws -> Double {
    log.info("embed_bench.http_post_started rows=\(inputs.count, privacy: .public)")

    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue(jsonContentType, forHTTPHeaderField: contentTypeHeader)
    request.httpBody = try JSONEncoder().encode(
      EmbeddingRequest(model: model, input: inputs)
    )

    let start = DispatchTime.now()
    let (data, response) = try await URLSession.shared.data(for: request)
    let end = DispatchTime.now()
    let seconds =
      Double(end.uptimeNanoseconds - start.uptimeNanoseconds) / nanosecondsPerSecond

    let statusCode = try statusCode(from: response, url: url)
    guard statusCode == httpOKStatusCode else {
      log.error("embed_bench.http_post_failed status=\(statusCode, privacy: .public)")
      throw EmbedBenchRunnerError.httpStatus(
        url: url.absoluteString,
        statusCode: statusCode,
        body: bodyString(data)
      )
    }

    let decoded = try JSONDecoder().decode(EmbeddingResponse.self, from: data)
    guard decoded.data.count == inputs.count else {
      log.error(
        "embed_bench.http_post_count_mismatch expected=\(inputs.count, privacy: .public) actual=\(decoded.data.count, privacy: .public)"
      )
      throw EmbedBenchRunnerError.responseCountMismatch(
        expected: inputs.count,
        actual: decoded.data.count
      )
    }

    log.info(
      "embed_bench.http_post_completed rows=\(inputs.count, privacy: .public) status=\(statusCode, privacy: .public) seconds=\(seconds, privacy: .public)"
    )
    return seconds
  }

  private static func fetchServerMetrics(baseURL: String) async throws -> ServerMetrics {
    log.info("embed_bench.metrics_fetch_started")

    let url = try endpoint(baseURL: baseURL, path: metricsPath)
    let (data, response) = try await URLSession.shared.data(from: url)
    let statusCode = try statusCode(from: response, url: url)
    guard statusCode == httpOKStatusCode else {
      log.error("embed_bench.metrics_fetch_failed status=\(statusCode, privacy: .public)")
      throw EmbedBenchRunnerError.httpStatus(
        url: url.absoluteString,
        statusCode: statusCode,
        body: bodyString(data)
      )
    }

    let snapshot = try JSONDecoder().decode(MergedMetricsSnapshot.self, from: data)
    let gauges = snapshot.metrics.gauges
      .filter { $0.name.hasPrefix(metricNamePrefix) }
      .sorted(by: scalarOrder)
    let histograms = snapshot.metrics.histograms
      .filter { $0.name.hasPrefix(metricNamePrefix) }
      .sorted(by: histogramOrder)
    log.info(
      "embed_bench.metrics_fetch_completed gauges=\(gauges.count, privacy: .public) histograms=\(histograms.count, privacy: .public)"
    )
    return ServerMetrics(gauges: gauges, histograms: histograms)
  }

  private static func statusCode(from response: URLResponse, url: URL) throws -> Int {
    guard let httpResponse = response as? HTTPURLResponse else {
      throw EmbedBenchRunnerError.nonHTTPResponse(url.absoluteString)
    }
    return httpResponse.statusCode
  }

  private static func bodyString(_ data: Data) -> String {
    String(data: data, encoding: .utf8) ?? "<non-utf8 body>"
  }

  private static func printJSON(_ summary: EmbedBenchSummary) throws {
    let encoder = JSONEncoder()
    encoder.keyEncodingStrategy = .convertToSnakeCase
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(summary)
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data("\n".utf8))
  }

  private static func printHuman(_ summary: EmbedBenchSummary) {
    say("lmd bench embed")
    say(row("model", summary.model))
    say(row("base_url", summary.baseURL))
    say("")
    say("client")
    say(row("requests", String(summary.requests)))
    say(row("rows_per_request", String(summary.rowsPerRequest)))
    say(row("total_rows", String(summary.clientReport.totalRows)))
    say(row("total_estimated_tokens", String(summary.clientReport.totalEstimatedTokens)))
    say(row("total_seconds", fixed(summary.clientReport.totalSeconds)))
    say(row("estimated_tokens_per_second", fixed(summary.clientReport.estimatedTokensPerSecond)))
    say(row("latency_p50_seconds", fixed(summary.clientReport.latencyP50Seconds)))
    say(row("latency_p95_seconds", fixed(summary.clientReport.latencyP95Seconds)))
    say("")
    say("server gauges")
    if summary.serverMetrics.gauges.isEmpty {
      say(row("lmd_embed_*", "none"))
    } else {
      for gauge in summary.serverMetrics.gauges {
        say(row(metricLabel(name: gauge.name, labels: gauge.labels), fixed(gauge.value)))
      }
    }
    say("")
    say("server histograms")
    if summary.serverMetrics.histograms.isEmpty {
      say(row("lmd_embed_*", "none"))
    } else {
      say(row("name", "count  sum  min  max  last"))
      for histogram in summary.serverMetrics.histograms {
        let value = String(
          format: "%d  %@  %@  %@  %@",
          histogram.count,
          fixed(histogram.sum),
          fixed(histogram.min),
          fixed(histogram.max),
          fixed(histogram.last)
        )
        say(row(metricLabel(name: histogram.name, labels: histogram.labels), value))
      }
    }
  }

  private static func say(_ string: String = "") {
    FileHandle.standardOutput.write((string + "\n").data(using: .utf8) ?? Data())
  }

  private static func row(_ name: String, _ value: String) -> String {
    if name.count >= tableNameColumnWidth {
      return String(format: "%@  %@", name, value)
    }
    let paddedName = name.padding(
      toLength: tableNameColumnWidth,
      withPad: " ",
      startingAt: 0
    )
    return String(format: "%@%@", paddedName, value)
  }

  private static func fixed(_ value: Double) -> String {
    String(format: "%.3f", value)
  }

  private static func metricLabel(name: String, labels: [String: String]) -> String {
    guard !labels.isEmpty else {
      return name
    }
    let renderedLabels = labels.sorted { $0.key < $1.key }
      .map { "\($0.key)=\($0.value)" }
      .joined(separator: ",")
    return "\(name){\(renderedLabels)}"
  }

  private static func scalarOrder(_ lhs: ServerGauge, _ rhs: ServerGauge) -> Bool {
    (lhs.name, labelKey(lhs.labels)) < (rhs.name, labelKey(rhs.labels))
  }

  private static func histogramOrder(
    _ lhs: ServerHistogram,
    _ rhs: ServerHistogram
  ) -> Bool {
    (lhs.name, labelKey(lhs.labels)) < (rhs.name, labelKey(rhs.labels))
  }

  private static func labelKey(_ labels: [String: String]) -> String {
    labels.sorted { $0.key < $1.key }
      .map { "\($0.key)=\($0.value)" }
      .joined(separator: ",")
  }
}

// MARK: - EmbedBenchRunnerError

public enum EmbedBenchRunnerError: CustomStringConvertible, Error, LocalizedError {
  case emptyCorpus
  case httpStatus(url: String, statusCode: Int, body: String)
  case invalidBaseURL(String)
  case invalidRequestCount(Int)
  case invalidRowsPerRequest(Int)
  case nonHTTPResponse(String)
  case responseCountMismatch(expected: Int, actual: Int)

  public var description: String {
    switch self {
    case let .invalidBaseURL(baseURL):
      return "invalid base URL: \(baseURL)"
    case let .invalidRowsPerRequest(rowsPerRequest):
      return "rows-per-request must be greater than zero: \(rowsPerRequest)"
    case let .invalidRequestCount(requests):
      return "requests must not be negative: \(requests)"
    case .emptyCorpus:
      return "corpus must contain at least one input when requests is greater than zero"
    case let .nonHTTPResponse(url):
      return "non-HTTP response from \(url)"
    case let .httpStatus(url, statusCode, body):
      return "HTTP \(statusCode) from \(url): \(body)"
    case let .responseCountMismatch(expected, actual):
      return "embedding response row count mismatch: expected \(expected), got \(actual)"
    }
  }

  public var errorDescription: String? {
    description
  }
}

// MARK: - EmbeddingRequest

private struct EmbeddingRequest: Encodable {
  let model: String
  let input: [String]
}

// MARK: - EmbeddingResponse

private struct EmbeddingResponse: Decodable {
  let data: [EmbeddingDatum]
}

// MARK: - EmbeddingDatum

private struct EmbeddingDatum: Decodable {}

// MARK: - EmbedBenchSummary

private struct EmbedBenchSummary: Encodable {
  let baseURL: String
  let model: String
  let requests: Int
  let rowsPerRequest: Int
  let clientReport: EmbedBenchStats.Report
  let batches: [EmbedBenchStats.BatchSample]
  let serverMetrics: ServerMetrics
}

// MARK: - ServerMetrics

private struct ServerMetrics: Codable {
  let gauges: [ServerGauge]
  let histograms: [ServerHistogram]
}

// MARK: - MergedMetricsSnapshot

private struct MergedMetricsSnapshot: Decodable {
  let metrics: MetricsPayload
}

// MARK: - MetricsPayload

private struct MetricsPayload: Decodable {
  let counters: [ServerCounter]
  let gauges: [ServerGauge]
  let histograms: [ServerHistogram]
}

// MARK: - ServerCounter

private struct ServerCounter: Codable {
  let name: String
  let value: Double
  let labels: [String: String]
}

// MARK: - ServerGauge

private struct ServerGauge: Codable {
  let name: String
  let value: Double
  let labels: [String: String]
}

// MARK: - ServerHistogram

private struct ServerHistogram: Codable {
  let name: String
  let count: Int
  let sum: Double
  let min: Double
  let max: Double
  let last: Double
  let labels: [String: String]
}
