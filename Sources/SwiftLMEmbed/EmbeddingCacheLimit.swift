//
//  EmbeddingCacheLimit.swift
//  SwiftLMEmbed
//
//  Created by Alex Goodkind <alex@goodkind.io> on 2026-05-23.
//  Copyright © 2026
//

import Foundation

private let defaultEmbeddingCacheLimitBytes = 2 * 1024 * 1024 * 1024

func configuredEmbeddingCacheLimitBytes() -> Int {
  guard let raw = ProcessInfo.processInfo.environment["LMD_MLX_CACHE_LIMIT_GB"],
    let gigabytes = Double(raw),
    gigabytes > 0
  else {
    return defaultEmbeddingCacheLimitBytes
  }
  return Int(gigabytes * 1_073_741_824)
}
