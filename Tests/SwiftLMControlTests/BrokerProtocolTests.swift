//
//  BrokerProtocolTests.swift
//  SwiftLMControlTests
//
//  Round-trips every BrokerRequest/BrokerResponse case through
//  JSONEncoder + JSONDecoder so an enum-evolution mistake (renamed
//  case, dropped associated value) fails loudly at build time.
//

import XCTest

@testable import SwiftLMControl

final class BrokerProtocolTests: XCTestCase {
  func testRequestRoundTrip() throws {
    let cases: [BrokerRequest] = [
      .health,
      .loaded,
      .preload(model: "qwen3"),
      .unload(model: "qwen3"),
      .pullStart(slug: "BAAI/bge-m3"),
      .embed(model: "snowflake", inputs: ["one", "two"]),
      .events,
    ]
    for request in cases {
      let encoded = try JSONEncoder().encode(request)
      let decoded = try JSONDecoder().decode(BrokerRequest.self, from: encoded)
      XCTAssertEqual(describe(decoded), describe(request))
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
          kind: "chat"
        )
      ]
    )
    let cases: [BrokerResponse] = [
      .ok,
      .loaded(snapshot),
      .preloaded(modelID: "qwen3"),
      .unloaded(modelID: "qwen3"),
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
      XCTAssertEqual(describe(decoded), describe(response))
    }
  }

  func testServiceNameStable() {
    XCTAssertEqual(brokerXPCServiceName, "io.goodkind.lmd.control")
  }

  // String(describing:) is good enough to compare enums with associated
  // values without forcing every payload type to conform to Equatable.
  private func describe<T>(_ value: T) -> String {
    String(describing: value)
  }
}
