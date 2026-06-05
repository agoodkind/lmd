//
//  PowerThrottleLevel.swift
//  SwiftLMCore
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-06-04.
//  Copyright © 2026, all rights reserved.
//

/// Graded embedding throttle level applied in response to battery pressure.
///
/// `none` is the unthrottled steady state. `mild` and `hard` progressively cap
/// embedding concurrency, add inter-request pacing, and (at `hard`) shrink the
/// MLX allocator cache. `PowerMonitor` computes the level from battery charge
/// and discharge rate; `ModelRouter` and the embedding backends apply it.
public enum PowerThrottleLevel: Int, Sendable, Equatable {
  case none = 0
  case mild = 1
  case hard = 2
}
