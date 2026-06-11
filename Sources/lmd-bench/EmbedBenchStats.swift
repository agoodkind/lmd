//
//  EmbedBenchStats.swift
//  lmd-bench
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-06-11.
//  Copyright © 2026, all rights reserved.
//

import Foundation

// MARK: - EmbedBenchStats

public enum EmbedBenchStats {
  public struct BatchSample: Codable, Equatable, Sendable {
    public let rows: Int
    public let estimatedTokens: Int
    public let seconds: Double

    public init(rows: Int, estimatedTokens: Int, seconds: Double) {
      self.rows = rows
      self.estimatedTokens = estimatedTokens
      self.seconds = seconds
    }
  }

  public struct Report: Codable, Equatable, Sendable {
    public let totalRows: Int
    public let totalEstimatedTokens: Int
    public let totalSeconds: Double
    public let estimatedTokensPerSecond: Double
    public let latencyP50Seconds: Double
    public let latencyP95Seconds: Double

    public init(
      totalRows: Int,
      totalEstimatedTokens: Int,
      totalSeconds: Double,
      estimatedTokensPerSecond: Double,
      latencyP50Seconds: Double,
      latencyP95Seconds: Double
    ) {
      self.totalRows = totalRows
      self.totalEstimatedTokens = totalEstimatedTokens
      self.totalSeconds = totalSeconds
      self.estimatedTokensPerSecond = estimatedTokensPerSecond
      self.latencyP50Seconds = latencyP50Seconds
      self.latencyP95Seconds = latencyP95Seconds
    }
  }

  private static let commonRollUpperBound: UInt64 = 70
  private static let mediumRollUpperBound: UInt64 = 95
  private static let distributionRollModulus: UInt64 = 100
  private static let commonTokenDivisor: Int = 2
  private static let mediumTokenMultiplier: Int = 2
  private static let mediumTokenSpreadMultiplier: Int = 4
  private static let longTokenMultiplier: Int = 8
  private static let longTokenSpreadMultiplier: Int = 4
  private static let bytesPerEstimatedToken: Int = 4
  private static let corpusUnit = "func "
  private static let minimumRepeatCount: Int = 1
  private static let percentileScale: Double = 100
  private static let percentileMedian: Double = 50
  private static let percentileTail: Double = 95

  public static func syntheticCorpus(count: Int, medianTokens: Int, seed: UInt64) -> [String] {
    precondition(count >= 0, "count must not be negative")

    let normalizedMedianTokens = max(medianTokens, 1)
    var generator = SplitMix64(state: seed)
    var corpus: [String] = []
    corpus.reserveCapacity(count)

    for _ in 0..<count {
      let roll = generator.next() % distributionRollModulus
      let tokenCount: Int
      if roll < commonRollUpperBound {
        tokenCount =
          normalizedMedianTokens / commonTokenDivisor
          + Int(generator.next() % UInt64(normalizedMedianTokens))
      } else if roll < mediumRollUpperBound {
        let tokenSpread = normalizedMedianTokens * mediumTokenSpreadMultiplier
        tokenCount =
          normalizedMedianTokens * mediumTokenMultiplier
          + Int(generator.next() % UInt64(tokenSpread))
      } else {
        let tokenSpread = normalizedMedianTokens * longTokenSpreadMultiplier
        tokenCount =
          normalizedMedianTokens * longTokenMultiplier
          + Int(generator.next() % UInt64(tokenSpread))
      }

      let targetBytes = tokenCount * bytesPerEstimatedToken
      let repeatCount = max(
        minimumRepeatCount,
        (targetBytes + corpusUnit.utf8.count - 1) / corpusUnit.utf8.count
      )
      corpus.append(String(repeating: corpusUnit, count: repeatCount))
    }

    return corpus
  }

  public static func percentile(_ values: [Double], _ pct: Double) -> Double {
    precondition(!values.isEmpty, "percentile requires at least one value")

    let sortedValues = values.sorted()
    if pct <= 0 {
      return sortedValues[0]
    }
    if pct >= percentileScale {
      return sortedValues[sortedValues.count - 1]
    }

    let percentilePosition =
      (pct / percentileScale) * Double(sortedValues.count - 1)
    let lowerIndex = Int(floor(percentilePosition))
    let upperIndex = Int(ceil(percentilePosition))
    if lowerIndex == upperIndex {
      return sortedValues[lowerIndex]
    }

    let weight = percentilePosition - Double(lowerIndex)
    let lowerValue = sortedValues[lowerIndex]
    let upperValue = sortedValues[upperIndex]
    return lowerValue + (upperValue - lowerValue) * weight
  }

  public static func makeReport(batches: [BatchSample]) -> Report {
    var totalRows = 0
    var totalEstimatedTokens = 0
    var totalSeconds = 0.0
    var latencies: [Double] = []
    latencies.reserveCapacity(batches.count)

    for batch in batches {
      totalRows += batch.rows
      totalEstimatedTokens += batch.estimatedTokens
      totalSeconds += batch.seconds
      latencies.append(batch.seconds)
    }

    let estimatedTokensPerSecond: Double
    if totalSeconds > 0 {
      estimatedTokensPerSecond = Double(totalEstimatedTokens) / totalSeconds
    } else {
      estimatedTokensPerSecond = 0
    }

    let latencyP50Seconds: Double
    let latencyP95Seconds: Double
    if latencies.isEmpty {
      latencyP50Seconds = 0
      latencyP95Seconds = 0
    } else {
      latencyP50Seconds = percentile(latencies, percentileMedian)
      latencyP95Seconds = percentile(latencies, percentileTail)
    }

    return Report(
      totalRows: totalRows,
      totalEstimatedTokens: totalEstimatedTokens,
      totalSeconds: totalSeconds,
      estimatedTokensPerSecond: estimatedTokensPerSecond,
      latencyP50Seconds: latencyP50Seconds,
      latencyP95Seconds: latencyP95Seconds
    )
  }
}

// MARK: - SplitMix64

private struct SplitMix64 {
  private static let increment: UInt64 = 0x9E37_79B9_7F4A_7C15
  private static let firstMultiplier: UInt64 = 0xBF58_476D_1CE4_E5B9
  private static let secondMultiplier: UInt64 = 0x94D0_49BB_1331_11EB
  private static let firstShift: UInt64 = 30
  private static let secondShift: UInt64 = 27
  private static let finalShift: UInt64 = 31

  var state: UInt64

  mutating func next() -> UInt64 {
    state &+= Self.increment
    var value = state
    value = (value ^ (value >> Self.firstShift)) &* Self.firstMultiplier
    value = (value ^ (value >> Self.secondShift)) &* Self.secondMultiplier
    return value ^ (value >> Self.finalShift)
  }
}
