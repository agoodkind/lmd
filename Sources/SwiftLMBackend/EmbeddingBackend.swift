//
//  EmbeddingBackend.swift
//  SwiftLMBackend
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-04-19.
//  Copyright © 2026, all rights reserved.
//

import Foundation
import SwiftLMCore

/// In process embedding backend. No TCP port. MLXEmbedders lives in SwiftLMEmbed.
public protocol EmbeddingBackendProtocol: AnyObject, Sendable {
  /// Same key as ``ModelDescriptor/id`` (disk path).
  var modelID: String { get }
  var sizeBytes: Int64 { get }
  func launch() async throws
  func shutdown()
  /// Run a forward pass for one batch of input strings. Vectors are L2 normalized when the pooler does so.
  func embed(inputs: [String]) async throws -> [[Float]]
  /// Apply a battery throttle level. MLX backends shrink the allocator cache at
  /// `hard` and restore it otherwise. The default is a no-op so backends that do
  /// not manage a GPU cache are unaffected.
  func applyPowerThrottle(_ level: PowerThrottleLevel)
}

extension EmbeddingBackendProtocol {
  public func applyPowerThrottle(_ level: PowerThrottleLevel) {}
}

public protocol UnsupportedEmbeddingBackendError: Error, CustomStringConvertible, Sendable {}
