//
//  EmbeddingBackend.swift
//  SwiftLMBackend
//
//  Created by Alex Goodkind <alex@goodkind.io> on 2026-04-19.
//  Copyright © 2026
//

import Foundation

/// In process embedding backend. No TCP port. MLXEmbedders lives in SwiftLMEmbed.
public protocol EmbeddingBackendProtocol: AnyObject, Sendable {
  /// Same key as ``ModelDescriptor/id`` (disk path).
  var modelID: String { get }
  var sizeBytes: Int64 { get }
  func shutdown()
  /// Run a forward pass for one batch of input strings. Vectors are L2 normalized when the pooler does so.
  func embed(inputs: [String]) async throws -> [[Float]]
}

