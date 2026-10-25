//
//  GemmaVideoTokenizerFixture.swift
//  SwiftLMBackendTests
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-10-25.
//  Copyright © 2026, all rights reserved.
//

import AppLogger
import Foundation
import XCTest

private let log = AppLogger.logger(category: "GemmaVideoTokenizerFixture")

enum GemmaVideoTokenizerFixture {
  private static let videoTokenID = 258_884
  private static let imageTokenID = 258_880
  private static let beginningOfImageTokenID = 255_999
  private static let endOfImageTokenID = 258_882

  static func modernize(at directory: URL) throws {
    let mappings = [
      (original: "<|video|>", modern: "<|video|>", identifier: videoTokenID),
      (original: "<start_of_image>", modern: "<|image>", identifier: beginningOfImageTokenID),
      (original: "<end_of_image>", modern: "<image|>", identifier: endOfImageTokenID),
    ]
    try updateJSON(at: directory.appendingPathComponent("tokenizer.json")) { json in
      var model = try XCTUnwrap(json["model"]?.object)
      var vocabulary = try XCTUnwrap(model["vocab"]?.object)
      var addedTokens = try XCTUnwrap(json["added_tokens"]?.array)
      for mapping in mappings {
        _ = try XCTUnwrap(vocabulary.removeValue(forKey: mapping.original))
        vocabulary[mapping.modern] = .number(Double(mapping.identifier))
        let index = try XCTUnwrap(
          addedTokens.firstIndex { $0.object?["content"]?.string == mapping.original })
        var token = try XCTUnwrap(addedTokens[index].object)
        token["content"] = .string(mapping.modern)
        token["id"] = .number(Double(mapping.identifier))
        addedTokens[index] = .object(token)
      }
      vocabulary["<|image|>"] = .number(Double(imageTokenID))
      addedTokens.append(
        .object([
          "id": .number(Double(imageTokenID)), "content": .string("<|image|>"),
          "special": .bool(true),
        ]))
      model["vocab"] = .object(vocabulary)
      json["model"] = .object(model)
      json["added_tokens"] = .array(addedTokens)
    }
    try updateJSON(at: directory.appendingPathComponent("tokenizer_config.json")) { json in
      json["additional_special_tokens"] = .array(
        (mappings.map(\.modern) + ["<|image|>"]).map(GemmaVideoFixtureValue.string))
    }
    let processorURL = directory.appendingPathComponent("preprocessor_config.json")
    try updateJSON(at: processorURL) { json in
      json["image_token_id"] = .number(Double(imageTokenID))
      json["video_token_id"] = .number(Double(videoTokenID))
      json["boi_token_id"] = .number(Double(beginningOfImageTokenID))
      json["eoi_token_id"] = .number(Double(endOfImageTokenID))
    }
  }

  private static func updateJSON(
    at url: URL, _ update: (inout [String: GemmaVideoFixtureValue]) throws -> Void
  ) throws {
    let data = try Data(contentsOf: url)
    let document = try JSONDecoder().decode(GemmaVideoFixtureValue.self, from: data)
    var json = try XCTUnwrap(document.object)
    try update(&json)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let updated = try encoder.encode(GemmaVideoFixtureValue.object(json))
    try updated.write(to: url)
    log.debug("fixture.rewritten path=\(url.path, privacy: .public)")
  }
}

// MARK: - GemmaVideoFixtureValue

private enum GemmaVideoFixtureValue: Codable {
  case array([GemmaVideoFixtureValue])
  case bool(Bool)
  case null
  case number(Double)
  case object([String: GemmaVideoFixtureValue])
  case string(String)

  var object: [String: GemmaVideoFixtureValue]? {
    guard case .object(let value) = self else { return nil }
    return value
  }

  var array: [GemmaVideoFixtureValue]? {
    guard case .array(let value) = self else { return nil }
    return value
  }

  var string: String? {
    guard case .string(let value) = self else { return nil }
    return value
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    if container.decodeNil() {
      self = .null
      return
    }
    if let value = try Self.decodeCandidate(Bool.self, from: container) {
      self = .bool(value)
      return
    }
    if let value = try Self.decodeCandidate(Double.self, from: container) {
      self = .number(value)
      return
    }
    if let value = try Self.decodeCandidate(String.self, from: container) {
      self = .string(value)
      return
    }
    if let value = try Self.decodeCandidate([GemmaVideoFixtureValue].self, from: container) {
      self = .array(value)
      return
    }
    self = .object(try container.decode([String: GemmaVideoFixtureValue].self))
  }

  private static func decodeCandidate<Candidate: Decodable>(
    _ type: Candidate.Type, from container: SingleValueDecodingContainer
  ) throws -> Candidate? {
    do {
      return try container.decode(type)
    } catch DecodingError.typeMismatch {
      return nil
    }
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
    case .array(let value):
      try container.encode(value)
    case .bool(let value):
      try container.encode(value)
    case .null:
      try container.encodeNil()
    case .number(let value):
      try container.encode(value)
    case .object(let value):
      try container.encode(value)
    case .string(let value):
      try container.encode(value)
    }
  }
}
