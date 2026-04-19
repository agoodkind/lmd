//
//  SwiftLMBackend.swift
//  SwiftLMBackend
//
//  Created by Alex Goodkind <alex@goodkind.io> on 2026-04-18.
//  Copyright © 2026
//

import Foundation

/// Namespace for SwiftLM subprocess lifecycle + HTTP proxying primitives.
///
/// Owns concrete process ownership concerns: spawning a SwiftLM child,
/// polling /health until ready, killing on shutdown, proxying requests.
/// Does not make orchestration decisions (those live in SwiftLMRuntime).
///
/// The namespace is named `SwiftLMBackendInfo` (not `SwiftLMBackend`) to
/// avoid a name clash with the module itself when callers try to write
/// `SwiftLMBackend.SomeType` to disambiguate from a local symbol.
public enum SwiftLMBackendInfo {
  public static let version = "0.1.0"
}
