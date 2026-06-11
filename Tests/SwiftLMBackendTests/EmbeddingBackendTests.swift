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

  func embed(inputs _: [String]) async throws -> [[Float]] { [] }
}

final class EmbeddingBackendTests: XCTestCase {
  func testDefaultCountTokensEstimatesFourBytesPerToken() {
    let backend = StubEmbeddingBackend()

    expect(backend.countTokens(inputs: ["abcdefgh"])) == 2
    expect(backend.countTokens(inputs: ["abcdefghi"])) == 3
    expect(backend.countTokens(inputs: [""])) == 1
    expect(backend.countTokens(inputs: ["abcdefgh", "abcdefgh"])) == 4
  }
}
