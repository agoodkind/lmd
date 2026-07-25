//
//  EmbeddingErrorEnvelopeTests.swift
//  SwiftLMHostProtocolTests
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-07-24.
//  Copyright © 2026, all rights reserved.
//

import Nimble
import XCTest

@testable import SwiftLMHostProtocol

final class EmbeddingErrorEnvelopeTests: XCTestCase {
  func testContextLengthMessageRoundTrips() {
    let message = EmbeddingErrorEnvelope.contextLengthMessage(
      limit: 4_096, tokenCount: 5_000, index: 2)

    expect(EmbeddingErrorEnvelope.isContextLength(message)) == true
    expect(message).to(contain("4096"))
    expect(message).to(contain("5000"))
    expect(message).to(contain("index 2"))
  }

  func testClientMessageStripsTheCode() {
    let message = EmbeddingErrorEnvelope.contextLengthMessage(
      limit: 4_096, tokenCount: 5_000, index: 0)
    let client = EmbeddingErrorEnvelope.clientMessage(message)

    expect(client.hasPrefix(EmbeddingErrorEnvelope.contextLengthCode)) == false
    expect(client.hasPrefix("This model's maximum context length")) == true
  }

  func testUnrelatedMessageIsNotContextLength() {
    let message = "embed failed: model not loaded"

    expect(EmbeddingErrorEnvelope.isContextLength(message)) == false
    expect(EmbeddingErrorEnvelope.clientMessage(message)) == message
  }
}
