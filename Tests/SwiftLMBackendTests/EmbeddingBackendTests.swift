//
//  EmbeddingBackendTests.swift
//  SwiftLMBackendTests
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-06-11.
//  Copyright © 2026, all rights reserved.
//

import Nimble
import XCTest

@testable import SwiftLMBackend

private final class StubEmbeddingBackend: EmbeddingBackendProtocol, @unchecked Sendable {
  var modelID = "stub"
  var sizeBytes: Int64 = 0

  func launch() async throws {}

  func shutdown() {}

  func embed(inputs _: [String]) -> EmbeddingForwardResult {
    EmbeddingForwardResult(rows: [], realTokens: 0)
  }
}

final class EmbeddingBackendTests: XCTestCase {
  func testDefaultCountTokensEstimatesFourBytesPerToken() {
    let backend = StubEmbeddingBackend()

    expect(backend.countTokens(inputs: ["abcdefgh"])) == 2
    expect(backend.countTokens(inputs: ["abcdefghi"])) == 3
    expect(backend.countTokens(inputs: [""])) == 1
    expect(backend.countTokens(inputs: ["abcdefgh", "abcdefgh"])) == 4
  }

  func testEmbeddingForwardResultCarriesRealTokens() {
    let result = EmbeddingForwardResult(rows: [[1, 2, 3]], realTokens: 7)

    expect(result.rows) == [[1, 2, 3]]
    expect(result.realTokens) == 7
  }
}
