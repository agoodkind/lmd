//
//  EmbeddingCacheLimit.swift
//  SwiftLMEmbed
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-05-23.
//  Copyright © 2026, all rights reserved.
//

import Foundation

private let defaultEmbeddingCacheLimitBytes = 2 * 1024 * 1024 * 1024

/// MLX allocator cache cap applied at the `hard` battery throttle level. Far
/// below the steady-state working set so the GPU footprint shrinks under
/// battery pressure; the backend restores `configuredEmbeddingCacheLimitBytes`
/// when the throttle releases.
let throttledEmbeddingCacheLimitBytes = 512 * 1024 * 1024

func configuredEmbeddingCacheLimitBytes() -> Int {
  guard let raw = ProcessInfo.processInfo.environment["LMD_MLX_CACHE_LIMIT_GB"],
    let gigabytes = Double(raw),
    gigabytes > 0
  else {
    return defaultEmbeddingCacheLimitBytes
  }
  return Int(gigabytes * 1_073_741_824)
}
