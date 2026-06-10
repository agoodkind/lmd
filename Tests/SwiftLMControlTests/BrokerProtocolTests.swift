//
//  BrokerProtocolTests.swift
//  SwiftLMControlTests
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-04-19.
//  Copyright © 2026, all rights reserved.
//
//  Round-trips every BrokerRequest/BrokerResponse case through
//  JSONEncoder + JSONDecoder so an enum-evolution mistake (renamed
//  case, dropped associated value) fails loudly at build time.
//

import Nimble
import XCTest

@testable import SwiftLMControl
@testable import SwiftLMCore
@testable import SwiftLMRuntime

final class BrokerProtocolTests: XCTestCase {
  func testRequestRoundTrip() throws {
    let cases: [BrokerRequest] = [
      .health,
      .loaded,
      .preload(request: .init(model: "qwen3", contextLength: 4_096, echoLoadConfig: true)),
      .unload(request: .init(model: "qwen3")),
      .pullStart(slug: "BAAI/bge-m3"),
      .embed(model: "snowflake", inputs: ["one", "two"]),
      .events,
    ]
    for request in cases {
      let encoded = try JSONEncoder().encode(request)
      let decoded = try JSONDecoder().decode(BrokerRequest.self, from: encoded)
      expect(self.describe(decoded)) == self.describe(request)
    }
  }

  func testResponseRoundTrip() throws {
    let snapshot = LoadedSnapshot(
      allocatedGB: 12.5,
      models: [
        .init(
          modelID: "qwen3",
          sizeGB: 12.5,
          lastUsed: Date(timeIntervalSince1970: 1_700_000_000),
          inFlightRequests: 1,
          kind: "chat",
          identifier: "reviewer",
          contextLength: 4_096,
          ttlSeconds: 300,
          loadConfig: ModelLoadConfig(
            identifier: "reviewer", contextLength: 4_096, ttlSeconds: 300),
          capabilities: ModelCapabilities(text: true, vision: true, video: true)
        )
      ]
    )
    let cases: [BrokerResponse] = [
      .ok,
      .loaded(snapshot),
      .preloaded(
        .init(
          type: "llm",
          instanceID: "reviewer",
          loadTimeSeconds: 1.2,
          status: "loaded",
          loadConfig: ModelLoadConfig(identifier: "reviewer", contextLength: 4_096)
        )),
      .unloaded(.init(status: "unloaded", modelIDs: ["qwen3"])),
      .event(.init(kind: .note, model: "qwen3", message: "loaded")),
      .pullEvent(.started(slug: "BAAI/bge-m3", destination: "/tmp/x")),
      .pullEvent(.progress(line: "12% done")),
      .pullCompleted(slug: "BAAI/bge-m3", destination: "/tmp/x"),
      .embeddings([[0.1, 0.2], [0.3, 0.4]]),
      .error(.init(kind: .modelNotFound, message: "missing")),
    ]
    for response in cases {
      let encoded = try JSONEncoder().encode(response)
      let decoded = try JSONDecoder().decode(BrokerResponse.self, from: encoded)
      expect(self.describe(decoded)) == self.describe(response)
    }
  }

  func testServiceNameStable() {
    expect(brokerXPCServiceName) == "io.goodkind.lmd.control"
  }

  // String(describing:) is good enough to compare enums with associated
  // values without forcing every payload type to conform to Equatable.
  private func describe<T>(_ value: T) -> String {
    String(describing: value)
  }
}
