//
//  SwiftLMMonitor.swift
//  SwiftLMMonitor
//
//  Created by Alex Goodkind <alex@goodkind.io> on 2026-04-18.
//  Copyright © 2026
//

import Foundation

/// Namespace for sensor sampling primitives.
///
/// Exposes wrappers for `pmset`, `vm_stat`, `memory_pressure`, and
/// `macmon`. Produces `Sample` values that clients can serialize or feed
/// to fan controllers. Does not make orchestration decisions.
public enum SwiftLMMonitor {
  public static let version = "0.1.0"
}
