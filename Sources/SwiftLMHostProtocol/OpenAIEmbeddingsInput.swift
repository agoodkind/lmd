//
//  OpenAIEmbeddingsInput.swift
//  SwiftLMHostProtocol
//
//  Decodes the `input` field of an OpenAI `/v1/embeddings` request body. The
//  model host reads the verbatim request body carried in `BackendRequest` and
//  needs the same string-or-array-of-strings rule the broker's HTTP handler
//  applies, so the rule lives here, shared and unit-tested, rather than being
//  duplicated in the helper.
//

import Foundation

/// Why an embeddings body could not be turned into a list of input strings.
public enum OpenAIEmbeddingsInputError: Error, Equatable {
  /// The bytes were not a JSON object.
  case malformedJSON
  /// `input` was absent, or was neither a string nor an array of strings.
  case inputMissingOrWrongType
}

public enum OpenAIEmbeddingsInput {
  /// Extract the embedding inputs from an OpenAI `/v1/embeddings` JSON body.
  /// `input` is either a single string or an array of strings; any other shape
  /// is rejected. An empty array decodes to an empty list, matching the
  /// broker's HTTP handler.
  public static func parse(_ body: Data) throws -> [String] {
    guard let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
      throw OpenAIEmbeddingsInputError.malformedJSON
    }
    if let single = json["input"] as? String {
      return [single]
    }
    if let array = json["input"] as? [Any] {
      var inputs: [String] = []
      inputs.reserveCapacity(array.count)
      for element in array {
        guard let string = element as? String else {
          throw OpenAIEmbeddingsInputError.inputMissingOrWrongType
        }
        inputs.append(string)
      }
      return inputs
    }
    throw OpenAIEmbeddingsInputError.inputMissingOrWrongType
  }
}
