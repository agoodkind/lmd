//
//  JSONEnforcement.swift
//  SwiftLMRuntime
//
//  Created by Alex Goodkind <alex@goodkind.io> on 2026-04-18.
//  Copyright © 2026
//

import AppLogger
import Foundation

private let log = AppLogger.logger(category: "JSONEnforcement")

// MARK: - JSON enforcement middleware

/// Inspect a chat-completion-style request body. If the caller asked for
/// a JSON response format, inject a strong system instruction so the
/// model actually emits JSON.
///
/// Local MLX servers do not implement the OpenAI `response_format` contract
/// at the decoder level. The keys `json_object` and `json_schema` are silently ignored
/// unless the prompt explicitly demands JSON. This middleware closes that
/// gap. After injection, the Qwen-Coder family hits near-100% parse rate
/// where it would otherwise emit prose.
///
/// - Parameter json: Parsed request body. Mutated in place when we inject.
/// - Returns: Re-serialized body data when a rewrite happened, `nil` if
///   no change was needed.
public func injectJSONInstructionIfNeeded(_ json: inout [String: Any]) -> Data? {
  guard let rf = json["response_format"] as? [String: Any],
        let type = rf["type"] as? String,
        type == "json_object" || type == "json_schema"
  else { return nil }

  var instruction = """
You MUST respond with a single valid JSON value. Do not include prose, \
preamble, apology, or markdown code fences. The entire response must \
parse with a standard JSON parser on the first try.
"""
  if type == "json_schema",
     let schema = rf["json_schema"] as? [String: Any],
     let body = schema["schema"] {
    if let data = try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys]),
       let text = String(data: data, encoding: .utf8) {
      instruction += "\n\nThe JSON must conform to this JSON schema:\n\(text)"
    }
  }

  var messages = (json["messages"] as? [[String: Any]]) ?? []
  if let idx = messages.firstIndex(where: { ($0["role"] as? String) == "system" }) {
    var msg = messages[idx]
    let existing = (msg["content"] as? String) ?? ""
    if !existing.lowercased().contains("json") {
      msg["content"] = existing + "\n\n" + instruction
      messages[idx] = msg
    } else {
      return nil  // caller already covered it; don't double-inject
    }
  } else {
    messages.insert(["role": "system", "content": instruction], at: 0)
  }
  json["messages"] = messages

  return try? JSONSerialization.data(withJSONObject: json)
}
