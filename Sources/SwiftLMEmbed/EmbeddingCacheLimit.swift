//
//  EmbeddingCacheLimit.swift
//  SwiftLMEmbed
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-05-23.
//  Copyright © 2026, all rights reserved.
//

private let defaultEmbeddingCacheLimitBytes = 2 * 1024 * 1024 * 1024

/// MLX allocator cache cap applied at the `hard` battery throttle level. Far
/// below the steady-state working set so the GPU footprint shrinks under
/// battery pressure; the backend restores `configuredEmbeddingCacheLimitBytes`
/// when the throttle releases.
let throttledEmbeddingCacheLimitBytes = 512 * 1024 * 1024

/// The configured MLX embedding cache cap, in bytes. The broker sets this once
/// at startup from `BrokerConfig` through `setConfiguredEmbeddingCacheLimitBytes`,
/// so this module no longer reads the environment. The default applies to
/// processes that never set it, such as unit tests.
private nonisolated(unsafe) var injectedEmbeddingCacheLimitBytes = defaultEmbeddingCacheLimitBytes

/// Set the configured MLX embedding cache cap. Call once during startup, before
/// any embedding backend is constructed.
public func setConfiguredEmbeddingCacheLimitBytes(_ bytes: Int) {
  injectedEmbeddingCacheLimitBytes = bytes
}

func configuredEmbeddingCacheLimitBytes() -> Int {
  injectedEmbeddingCacheLimitBytes
}
