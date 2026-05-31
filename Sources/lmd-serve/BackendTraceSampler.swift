//
//  BackendTraceSampler.swift
//  lmd-serve
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-05-18.
//  Copyright © 2026, all rights reserved.
//
//  Background ticker that emits BackendTrace `phase=tick` lines while
//  any backend is loaded. Provides time-series MLX memory data
//  independent of request timing so allocator drift between requests is
//  visible to the trace consumer.
//

import AppLogger
import Foundation
import SwiftLMRuntime
import SwiftLMTrace

/// 1 Hz background sampler. Cooperates with structured concurrency:
/// the spawned `Task` is cancellation-aware so callers can stop it by
/// dropping the returned handle.
public actor BackendTraceSampler {
  private let router: ModelRouter
  private let intervalNanos: UInt64
  private var task: Task<Void, Never>?

  public init(router: ModelRouter, intervalSeconds: Double = 1.0) {
    self.router = router
    self.intervalNanos = UInt64(intervalSeconds * 1_000_000_000)
  }

  public func start() {
    guard task == nil else {
      return
    }
    let router = self.router
    let interval = intervalNanos
    task = Task {
      while !Task.isCancelled {
        let infos = await router.loadedModelInfos()
        if !infos.isEmpty {
          let snapshot = MemorySnapshot.current()
          let loadedModelsField = Self.encodeLoadedModels(infos)
          // One trace line per tick, but emitted once per kind so each
          // line carries a meaningful model_kind. If multiple models of
          // different kinds are loaded, we emit one tick per loaded model.
          for info in infos {
            let context = TraceContext(
              modelID: info.modelID,
              modelKind: info.kind,
              loadID: info.loadID,
              backendObjectID: info.backendObjectID
            )
            BackendTrace.notice(
              phase: TracePhase.Common.tick.rawValue,
              context: context,
              snapshot: snapshot,
              extras: [
                "loaded_count": "\(infos.count)",
                "loaded_models": loadedModelsField,
              ]
            )
          }
        }
        try? await Task.sleep(nanoseconds: interval)
      }
    }
  }

  public func stop() {
    task?.cancel()
    task = nil
  }

  /// Compact JSON-ish array of {id,kind,load_id} triples. We render
  /// manually rather than via JSONEncoder because the field needs to
  /// stay on a single log line and the field values are simple enough.
  private static func encodeLoadedModels(_ infos: [ModelRouter.LoadedModelInfo]) -> String {
    let parts = infos.map { info in
      "{id=\(info.modelID),kind=\(info.kind.rawValue),load_id=\(info.loadID.uuidString)}"
    }
    return "[\(parts.joined(separator: ","))]"
  }
}
