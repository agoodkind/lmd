//
//  EmbeddingErrorEnvelope.swift
//  SwiftLMHostProtocol
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-07-24.
//  Copyright © 2026, all rights reserved.
//

import Foundation

// MARK: - EmbeddingErrorEnvelope

/// Serializes an over-length embedding rejection into the single `message`
/// string a `.failed` frame carries, and recovers it broker-side. The model
/// host tokenizes and detects the over-length input, but the broker owns the
/// HTTP status, so the two processes share this one code instead of a magic
/// string duplicated across the boundary.
public enum EmbeddingErrorEnvelope {
  /// OpenAI error code for an input past the model's context window.
  public static let contextLengthCode = "context_length_exceeded"

  private static let messagePrefix = contextLengthCode + ": "

  /// Build the `.failed` message the host sends when one input is too long.
  public static func contextLengthMessage(limit: Int, tokenCount: Int, index: Int) -> String {
    messagePrefix
      + "This model's maximum context length is \(limit) tokens, however the input at "
      + "index \(index) resolved to \(tokenCount) tokens. Reduce the input length."
  }

  /// Whether a `.failed` message encodes an over-length rejection.
  public static func isContextLength(_ message: String) -> Bool {
    message.hasPrefix(messagePrefix)
  }

  /// The client-facing message with the machine code prefix removed.
  public static func clientMessage(_ message: String) -> String {
    guard message.hasPrefix(messagePrefix) else {
      return message
    }
    return String(message.dropFirst(messagePrefix.count))
  }
}
