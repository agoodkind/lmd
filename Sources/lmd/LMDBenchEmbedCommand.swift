//
//  LMDBenchEmbedCommand.swift
//  lmd
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-06-11.
//  Copyright © 2026, all rights reserved.
//

import AppLogger
import ArgumentParser
import Foundation
import LMDBenchTool

private let log = AppLogger.logger(category: "DispatcherCLI")

// MARK: - LMDBenchEmbedCommand

struct LMDBenchEmbedCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "embed",
    abstract: "Benchmark the embedding path end to end over HTTP."
  )

  @Option(help: "Embedding model id.")
  var model: String = "nvidia/NV-EmbedCode-7b-v1"

  @Option(name: .customLong("base-url"), help: "Broker base URL.")
  var baseURL: String = "http://localhost:5400"

  @Option(help: "Corpus file, one input per line. Omit for synthetic.")
  var corpus: String?

  @Option(help: "Number of requests.")
  var requests: Int = 20

  @Option(name: .customLong("rows-per-request"), help: "Inputs per request.")
  var rowsPerRequest: Int = 64

  @Option(help: "Synthetic corpus median token length.")
  var medianTokens: Int = 93

  @Option(help: "Deterministic seed.")
  var seed: UInt64 = 42

  @Flag(help: "Emit the report as JSON.")
  var json = false

  mutating func run() async throws {
    let requestCount = requests
    let rowCount = rowsPerRequest
    let modelID = model
    let brokerBaseURL = baseURL
    let corpusPath = corpus
    let syntheticMedianTokens = medianTokens
    let syntheticSeed = seed
    let shouldEmitJSON = json

    log.notice(
      "bench.embed_started requests=\(requestCount, privacy: .public) rows_per_request=\(rowCount, privacy: .public)"
    )

    let texts: [String]
    if let corpusPath {
      texts = try String(contentsOfFile: corpusPath, encoding: .utf8)
        .split(separator: "\n")
        .map(String.init)
    } else {
      texts = EmbedBenchStats.syntheticCorpus(
        count: requestCount * rowCount,
        medianTokens: syntheticMedianTokens,
        seed: syntheticSeed
      )
    }

    try await EmbedBenchRunner.run(
      EmbedBenchRunConfiguration(
        baseURL: brokerBaseURL,
        model: modelID,
        corpus: texts,
        rowsPerRequest: rowCount,
        requests: requestCount,
        jsonOutput: shouldEmitJSON
      )
    )
  }
}
