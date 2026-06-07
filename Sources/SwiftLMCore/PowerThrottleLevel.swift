//
//  PowerThrottleLevel.swift
//  SwiftLMCore
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-06-04.
//  Copyright © 2026, all rights reserved.
//

/// Graded throttle level applied in response to battery pressure.
///
/// `none` is the unthrottled steady state. `mild` caps embedding concurrency and
/// adds inter-request pacing as a lead-in slow-down. `hard` is the stop: it
/// applies the strongest embedding caps, shrinks the MLX allocator cache, and
/// makes `ModelRouter` refuse new chat and embedding requests with HTTP 503
/// while in-flight requests drain. `PowerMonitor` computes the level from
/// battery charge; `ModelRouter` and the embedding backends apply it.
public enum PowerThrottleLevel: Int, Sendable, Equatable {
  case none = 0
  case mild = 1
  case hard = 2
}
