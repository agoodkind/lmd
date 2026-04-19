//
//  JSONEnforcementTests.swift
//  SwiftLMRuntimeTests
//
//  Created by Alex Goodkind <alex@goodkind.io> on 2026-04-18.
//  Copyright © 2026
//

import XCTest
@testable import SwiftLMRuntime

final class JSONEnforcementTests: XCTestCase {
  private func body(_ obj: [String: Any]) -> [String: Any] { obj }

  /// Parse the returned data back into a dict for assertions.
  private func decode(_ data: Data?) -> [String: Any]? {
    guard let d = data else { return nil }
    return try? JSONSerialization.jsonObject(with: d) as? [String: Any]
  }

  // MARK: - No-op paths

  func testNoResponseFormatIsNoOp() {
    var json = body([
      "model": "x",
      "messages": [["role": "user", "content": "hi"]],
    ])
    XCTAssertNil(injectJSONInstructionIfNeeded(&json))
  }

  func testResponseFormatTextIsNoOp() {
    var json = body([
      "model": "x",
      "messages": [["role": "user", "content": "hi"]],
      "response_format": ["type": "text"],
    ])
    XCTAssertNil(injectJSONInstructionIfNeeded(&json))
  }

  func testSystemAlreadyMentionsJSONIsNoOp() {
    var json = body([
      "model": "x",
      "messages": [
        ["role": "system", "content": "You are helpful. Return JSON only."],
        ["role": "user", "content": "hi"],
      ],
      "response_format": ["type": "json_object"],
    ])
    XCTAssertNil(injectJSONInstructionIfNeeded(&json))
  }

  // MARK: - Injection paths

  func testJSONObjectInjectsNewSystemMessage() throws {
    var json = body([
      "model": "x",
      "messages": [["role": "user", "content": "hi"]],
      "response_format": ["type": "json_object"],
    ])
    let out = injectJSONInstructionIfNeeded(&json)
    XCTAssertNotNil(out)

    let parsed = decode(out)
    let messages = parsed?["messages"] as? [[String: Any]] ?? []
    XCTAssertEqual(messages.count, 2)
    XCTAssertEqual(messages.first?["role"] as? String, "system")
    let content = (messages.first?["content"] as? String) ?? ""
    XCTAssertTrue(content.contains("JSON"))
    XCTAssertEqual(messages.last?["role"] as? String, "user")
  }

  func testJSONObjectAppendsToExistingSystemMessage() throws {
    var json = body([
      "model": "x",
      "messages": [
        ["role": "system", "content": "You are a helpful assistant."],
        ["role": "user", "content": "hi"],
      ],
      "response_format": ["type": "json_object"],
    ])
    let out = injectJSONInstructionIfNeeded(&json)
    XCTAssertNotNil(out)

    let parsed = decode(out)
    let messages = parsed?["messages"] as? [[String: Any]] ?? []
    XCTAssertEqual(messages.count, 2)
    let sysContent = (messages.first?["content"] as? String) ?? ""
    XCTAssertTrue(sysContent.contains("You are a helpful assistant."))
    XCTAssertTrue(sysContent.contains("JSON"))
  }

  func testJSONSchemaIncludesSchemaInInstruction() throws {
    let schemaBody: [String: Any] = [
      "type": "object",
      "properties": ["name": ["type": "string"]],
      "required": ["name"],
    ]
    var json = body([
      "model": "x",
      "messages": [["role": "user", "content": "hi"]],
      "response_format": [
        "type": "json_schema",
        "json_schema": [
          "name": "Person",
          "schema": schemaBody,
        ],
      ],
    ])
    let out = injectJSONInstructionIfNeeded(&json)
    XCTAssertNotNil(out)

    let parsed = decode(out)
    let messages = parsed?["messages"] as? [[String: Any]] ?? []
    let sysContent = (messages.first?["content"] as? String) ?? ""
    XCTAssertTrue(sysContent.contains("conform to this JSON schema"))
    // The schema body is embedded with sorted keys.
    XCTAssertTrue(sysContent.contains("\"properties\""))
    XCTAssertTrue(sysContent.contains("\"name\""))
  }

  func testJSONSchemaWithoutSchemaBodyStillInjectsBaseInstruction() {
    var json = body([
      "model": "x",
      "messages": [["role": "user", "content": "hi"]],
      "response_format": [
        "type": "json_schema",
        // no "json_schema.schema"
      ],
    ])
    let out = injectJSONInstructionIfNeeded(&json)
    XCTAssertNotNil(out)
    let parsed = decode(out)
    let messages = parsed?["messages"] as? [[String: Any]] ?? []
    let sysContent = (messages.first?["content"] as? String) ?? ""
    XCTAssertTrue(sysContent.contains("JSON"))
    XCTAssertFalse(sysContent.contains("conform to this JSON schema"))
  }
}
