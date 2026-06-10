//
//  JSONEnforcementTests.swift
//  SwiftLMRuntimeTests
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-04-18.
//  Copyright © 2026, all rights reserved.
//

import Nimble
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
    expect(injectJSONInstructionIfNeeded(&json)) == nil
  }

  func testResponseFormatTextIsNoOp() {
    var json = body([
      "model": "x",
      "messages": [["role": "user", "content": "hi"]],
      "response_format": ["type": "text"],
    ])
    expect(injectJSONInstructionIfNeeded(&json)) == nil
  }

  func testSystemMentioningJSONStillGetsJSONSchemaInstruction() {
    let schemaBody: [String: Any] = [
      "type": "object",
      "properties": ["name": ["type": "string"]],
      "required": ["name"],
    ]
    var json = body([
      "model": "x",
      "messages": [
        ["role": "system", "content": "You are helpful. Return JSON only."],
        ["role": "user", "content": "hi"],
      ],
      "response_format": [
        "type": "json_schema",
        "json_schema": [
          "name": "Person",
          "schema": schemaBody,
        ],
      ],
    ])
    let out = injectJSONInstructionIfNeeded(&json)
    expect(out) != nil

    let parsed = decode(out)
    let messages = parsed?["messages"] as? [[String: Any]] ?? []
    let sysContent = (messages.first?["content"] as? String) ?? ""
    expect(sysContent.contains("Return JSON only.")) == true
    expect(sysContent.contains("You MUST respond with a single valid JSON value.")) == true
    expect(sysContent.contains("conform to this JSON schema")) == true
  }

  // MARK: - Injection paths

  func testJSONObjectInjectsNewSystemMessage() {
    var json = body([
      "model": "x",
      "messages": [["role": "user", "content": "hi"]],
      "response_format": ["type": "json_object"],
    ])
    let out = injectJSONInstructionIfNeeded(&json)
    expect(out) != nil

    let parsed = decode(out)
    let messages = parsed?["messages"] as? [[String: Any]] ?? []
    expect(messages.count) == 2
    expect(messages.first?["role"] as? String) == "system"
    let content = (messages.first?["content"] as? String) ?? ""
    expect(content.contains("JSON")) == true
    expect(messages.last?["role"] as? String) == "user"
  }

  func testJSONObjectAppendsToExistingSystemMessage() {
    var json = body([
      "model": "x",
      "messages": [
        ["role": "system", "content": "You are a helpful assistant."],
        ["role": "user", "content": "hi"],
      ],
      "response_format": ["type": "json_object"],
    ])
    let out = injectJSONInstructionIfNeeded(&json)
    expect(out) != nil

    let parsed = decode(out)
    let messages = parsed?["messages"] as? [[String: Any]] ?? []
    expect(messages.count) == 2
    let sysContent = (messages.first?["content"] as? String) ?? ""
    expect(sysContent.contains("You are a helpful assistant.")) == true
    expect(sysContent.contains("JSON")) == true
  }

  func testJSONSchemaIncludesSchemaInInstruction() {
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
    expect(out) != nil

    let parsed = decode(out)
    let messages = parsed?["messages"] as? [[String: Any]] ?? []
    let sysContent = (messages.first?["content"] as? String) ?? ""
    expect(sysContent.contains("conform to this JSON schema")) == true
    // The schema body is embedded with sorted keys.
    expect(sysContent.contains("\"properties\"")) == true
    expect(sysContent.contains("\"name\"")) == true
  }

  func testJSONSchemaWithoutSchemaBodyStillInjectsBaseInstruction() {
    var json = body([
      "model": "x",
      "messages": [["role": "user", "content": "hi"]],
      "response_format": [
        "type": "json_schema"
          // no "json_schema.schema"
      ],
    ])
    let out = injectJSONInstructionIfNeeded(&json)
    expect(out) != nil
    let parsed = decode(out)
    let messages = parsed?["messages"] as? [[String: Any]] ?? []
    let sysContent = (messages.first?["content"] as? String) ?? ""
    expect(sysContent.contains("JSON")) == true
    expect(sysContent.contains("conform to this JSON schema")) == false
  }

  func testExactExistingJSONSchemaInstructionIsNoOp() {
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
    let first = injectJSONInstructionIfNeeded(&json)
    let parsed = decode(first)
    expect(parsed) != nil

    guard var rewritten = parsed else {
      fail("expected rewritten payload")
      return
    }
    expect(injectJSONInstructionIfNeeded(&rewritten)) == nil
  }
}
