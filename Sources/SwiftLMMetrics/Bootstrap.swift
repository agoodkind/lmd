//
//  Bootstrap.swift
//  SwiftLMMetrics
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-06-06.
//  Copyright © 2026, all rights reserved.
//
//  Convenience bootstrap helpers for process-local metrics identity.
//

import Foundation

public enum SwiftLMMetrics {
  public static func bootstrap(
    process: String,
    sourceID: String,
    modelID: String? = nil,
    modelKind: String? = nil
  ) {
    SnapshotSink.shared.configure(
      source: MetricsSource(
        sourceID: sourceID,
        process: process,
        modelID: modelID,
        modelKind: modelKind
      ))
  }
}
