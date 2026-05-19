//
//  MemorySnapshot.swift
//  SwiftLMTrace
//
//  Created by Alex Goodkind <alex@goodkind.io> on 2026-05-18.
//  Copyright © 2026
//
//  Process-global memory snapshot wrapper for MLX's allocator accounting.
//  Used by every BackendTrace caller so cache vs active memory deltas can
//  be observed at any lifecycle or per-request boundary.
//

import Foundation
import MLX
import MLXLMCommon

/// Active, cache, and peak byte counts reported by `MLX.Memory.snapshot()`.
///
/// `MLX.Memory` is process-global, not per-backend, so the same accessor
/// works for chat, embedding, and video backends in the same `lmd-serve`
/// process.
public struct MemorySnapshot: Sendable, Equatable {
  public let active: Int
  public let cache: Int
  public let peak: Int

  public init(active: Int = 0, cache: Int = 0, peak: Int = 0) {
    self.active = active
    self.cache = cache
    self.peak = peak
  }

  public static let zero = MemorySnapshot()

  /// Whether `current()` should consult MLX. Defaults to on. Tests that
  /// run without a Metal-backed environment set
  /// `LMD_TRACE_DISABLE_MLX_SNAPSHOT=1` to opt out, since `Memory.snapshot()`
  /// triggers Metal initialization which fatally aborts when the
  /// default metallib resource is unavailable.
  private static let mlxSnapshotEnabled: Bool = {
    let raw = ProcessInfo.processInfo.environment["LMD_TRACE_DISABLE_MLX_SNAPSHOT"]
    if let raw, !raw.isEmpty, raw != "0" {
      return false
    }
    return true
  }()

  /// Current MLX memory accounting from `MLX.Memory.snapshot()`. Returns
  /// `MemorySnapshot.zero` when the live snapshot is disabled via the
  /// env var above, which keeps unit tests that never touch real MLX
  /// from aborting on Metal initialization.
  public static func current() -> MemorySnapshot {
    guard mlxSnapshotEnabled else {
      return .zero
    }
    let snap = Memory.snapshot()
    return MemorySnapshot(
      active: snap.activeMemory,
      cache: snap.cacheMemory,
      peak: snap.peakMemory
    )
  }

  public var formattedFields: String {
    "mlx_active=\(active) mlx_cache=\(cache) mlx_peak=\(peak)"
  }
}
