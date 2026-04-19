//
//  ModelDescriptor.swift
//  SwiftLMCore
//
//  Created by Alex Goodkind <alex@goodkind.io> on 2026-04-18.
//  Copyright © 2026
//

import Foundation

// MARK: - ModelKind

/// High level model capability for routing and HTTP validation.
public enum ModelKind: String, Sendable, Codable {
  /// Generative chat model served by a SwiftLM subprocess.
  case chat
  /// Text embedding model served in process via MLXEmbedders.
  case embedding
}

// MARK: - ModelDescriptor

/// A single MLX model discovered on disk.
///
/// The catalog walks roots and yields one descriptor per model. Larger
/// per model metadata (ctx size, quant type, family) comes from parsing
/// the model's own `config.json` lazily.
public struct ModelDescriptor: Hashable, Sendable {
  /// Stable identifier used in API requests. The full disk path today.
  public let id: String
  /// Human readable short name (last path component).
  public let displayName: String
  /// Absolute path to the model directory.
  public let path: String
  /// Total bytes consumed on disk. 0 means "not measured".
  public let sizeBytes: Int64
  /// HuggingFace style `publisher/name` slug, if derivable.
  public let slug: String?
  /// Whether this model is routed to chat (SwiftLM) or embeddings (MLX).
  public let kind: ModelKind

  public init(
    id: String,
    displayName: String,
    path: String,
    sizeBytes: Int64 = 0,
    slug: String? = nil,
    kind: ModelKind = .chat
  ) {
    self.id = id
    self.displayName = displayName
    self.path = path
    self.sizeBytes = sizeBytes
    self.slug = slug
    self.kind = kind
  }
}
