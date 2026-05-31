//
//  ModelDescriptor.swift
//  SwiftLMCore
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-04-18.
//  Copyright © 2026, all rights reserved.
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

// MARK: - ModelCapabilities

/// Modalities advertised by a model, independent from routing kind.
public struct ModelCapabilities: Hashable, Sendable, Codable {
  public let text: Bool
  public let vision: Bool
  public let video: Bool
  /// Frame rate the model's preprocessor expects when the caller supplies
  /// pre-sampled video frames. The video route consults this value to size
  /// the [VideoFrame] array it passes to the backend. `nil` for non-video
  /// models or video-capable models with no detected sampling rate.
  public let videoSamplingFPS: Double?

  public init(
    text: Bool = true,
    vision: Bool = false,
    video: Bool = false,
    videoSamplingFPS: Double? = nil
  ) {
    self.text = text
    self.vision = vision
    self.video = video
    self.videoSamplingFPS = videoSamplingFPS
  }

  enum CodingKeys: String, CodingKey {
    case text
    case vision
    case video
    case videoSamplingFPS = "video_sampling_fps"
  }

  public static let textOnly = ModelCapabilities()
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
  /// Modalities the model advertises through structured metadata.
  public let capabilities: ModelCapabilities

  public init(
    id: String,
    displayName: String,
    path: String,
    sizeBytes: Int64 = 0,
    slug: String? = nil,
    kind: ModelKind = .chat,
    capabilities: ModelCapabilities = .textOnly
  ) {
    self.id = id
    self.displayName = displayName
    self.path = path
    self.sizeBytes = sizeBytes
    self.slug = slug
    self.kind = kind
    self.capabilities = capabilities
  }
}
