//
//  SwiftLMRuntime.swift
//  SwiftLMRuntime
//
//  Created by Alex Goodkind <alex@goodkind.io> on 2026-04-18.
//  Copyright © 2026
//

import Foundation

/// Namespace for high-level orchestration primitives.
///
/// Holds the model catalog, request router, eviction policy, memory budget,
/// and fan coordinator. Does not know about HTTP wire formats or terminal
/// rendering. Those live in their respective layers.
public enum SwiftLMRuntime {
  public static let version = "0.1.0"
}
