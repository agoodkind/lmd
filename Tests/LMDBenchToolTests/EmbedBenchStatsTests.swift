//
//  EmbedBenchStatsTests.swift
//  LMDBenchToolTests
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-06-11.
//  Copyright © 2026, all rights reserved.
//

import Nimble
import XCTest

@testable import LMDBenchTool

final class EmbedBenchStatsTests: XCTestCase {
  func testSyntheticCorpusIsDeterministicAndShaped() throws {
    let first = EmbedBenchStats.syntheticCorpus(count: 500, medianTokens: 93, seed: 42)
    let second = EmbedBenchStats.syntheticCorpus(count: 500, medianTokens: 93, seed: 42)
    expect(first) == second
    expect(first.count) == 500
    let estimated = first.map { ($0.utf8.count + 3) / 4 }.sorted()
    let median = estimated[250]
    expect(Double(median)).to(beCloseTo(93, within: 30))
    let last = try XCTUnwrap(estimated.last)
    expect(last) > 800
  }

  func testPercentileInterpolation() {
    let values: [Double] = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10]
    expect(EmbedBenchStats.percentile(values, 50)) == 5.5
    expect(EmbedBenchStats.percentile(values, 95)).to(beCloseTo(9.55, within: 0.01))
  }

  func testReportComputesTokensPerSecond() {
    let report = EmbedBenchStats.makeReport(
      batches: [
        EmbedBenchStats.BatchSample(rows: 32, estimatedTokens: 3_000, seconds: 3.0),
        EmbedBenchStats.BatchSample(rows: 32, estimatedTokens: 6_000, seconds: 3.0),
      ])
    expect(report.totalRows) == 64
    expect(report.estimatedTokensPerSecond).to(beCloseTo(1_500, within: 0.01))
    expect(report.latencyP50Seconds) == 3.0
  }
}
