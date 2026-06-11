//
//  EmbeddingHost.swift
//  lmd-model-host
//
//  Serves embedding requests in-process. The host builds a ModelDescriptor for
//  the model path the broker passed in argv, loads the MLX embedding backend
//  through the same factory the broker used to use in-process, and answers each
//  BackendRequest with one `vectors` frame, a `usage` frame, and a terminal
//  `done`, or a single `failed` frame on any error.
//

import AppLogger
import Dispatch
import Foundation
import SwiftLMBackend
import SwiftLMCore
import SwiftLMEmbed
import SwiftLMHostProtocol
import SwiftLMMetrics
import SwiftLMTrace

private let log = AppLogger.logger(category: "EmbeddingHost")

/// In-process embedding serving for `lmd-model-host`. Holds the loaded backend
/// and turns a `BackendRequest` into the broker-facing frame sequence.
actor EmbeddingHost {
  private let modelPath: String
  let tuning: EmbeddingRuntimeTuning
  private var backend: EmbeddingBackendProtocol?

  init(modelPath: String, tuning: EmbeddingRuntimeTuning = .fallback) {
    self.modelPath = modelPath
    self.tuning = tuning
  }

  /// Build the descriptor and load the embedding backend. The catalog keys a
  /// model's identity on its real path, so `id` and `path` are both the model
  /// path here; the helper never needs the catalog's slug or size for serving.
  func load() async throws {
    let descriptor = ModelDescriptor(
      id: modelPath,
      displayName: (modelPath as NSString).lastPathComponent,
      path: modelPath,
      kind: .embedding
    )
    let backend = try EmbeddingBackendFactory.makeBackend(descriptor: descriptor)
    try await backend.launch()
    self.backend = backend
    log.notice(
      "embedding.host_tuning slot_budget=\(self.tuning.slotBudget, privacy: .public) max_rows=\(self.tuning.maxRows, privacy: .public) forwards=\(self.tuning.maxConcurrentForwards, privacy: .public) lane=\(self.tuning.priorityLaneEnabled, privacy: .public)"
    )
  }

  /// Apply a battery throttle level to the loaded backend so it shrinks the MLX
  /// allocator cache at `hard` and restores it otherwise, the behavior the
  /// in-process router drove before embedding moved to this helper. A no-op when
  /// the backend has not loaded yet; the level the broker resends after load
  /// recovers the state.
  func applyPowerThrottle(_ level: ThrottleLevel) {
    let mapped: PowerThrottleLevel
    switch level {
    case .none:
      mapped = .none
    case .mild:
      mapped = .mild
    case .hard:
      mapped = .hard
    }
    backend?.applyPowerThrottle(mapped)
  }

  /// Run one embedding request and return the frames to send back, in order.
  /// Decoding, the forward pass, and encoding all happen here; any thrown error
  /// is mapped to a single `failed` frame by the caller.
  func frames(for request: BackendRequest) async -> [BackendFrame] {
    await SwiftLMMetrics.withRequestSpan(
      "embedding.request",
      modelID: modelPath,
      modelKind: "embedding",
      requestID: request.requestID
    ) {
      await framesInSpan(for: request)
    }
  }

  private func framesInSpan(for request: BackendRequest) async -> [BackendFrame] {
    let requestStartedAt = Date()
    let requestStartedNanoseconds = DispatchTime.now().uptimeNanoseconds
    guard let backend else {
      recordRequestSpan(
        request: request,
        startedAt: requestStartedAt,
        startedNanoseconds: requestStartedNanoseconds,
        outcome: "failed",
        attributes: ["error": "embedding model not loaded"]
      )
      return [.failed(requestID: request.requestID, message: "embedding model not loaded")]
    }
    let inputs: [String]
    do {
      inputs = try OpenAIEmbeddingsInput.parse(request.openAIBody)
    } catch {
      recordRequestSpan(
        request: request,
        startedAt: requestStartedAt,
        startedNanoseconds: requestStartedNanoseconds,
        outcome: "failed",
        attributes: ["error": "bad embeddings input: \(error)"]
      )
      return [.failed(requestID: request.requestID, message: "bad embeddings input: \(error)")]
    }
    let vectors: [[Float]]
    do {
      vectors = try await TraceTaskLocal.$requestID.withValue(request.requestID) {
        try await backend.embed(inputs: inputs)
      }
    } catch {
      recordRequestSpan(
        request: request,
        startedAt: requestStartedAt,
        startedNanoseconds: requestStartedNanoseconds,
        outcome: "failed",
        attributes: [
          "error": "embed failed: \(error)",
          "input_count": "\(inputs.count)",
        ]
      )
      return [.failed(requestID: request.requestID, message: "embed failed: \(error)")]
    }
    let (dims, payload) = VectorBlob.encode(vectors)
    recordRequestSpan(
      request: request,
      startedAt: requestStartedAt,
      startedNanoseconds: requestStartedNanoseconds,
      outcome: "completed",
      attributes: [
        "dims": "\(dims)",
        "input_count": "\(inputs.count)",
        "vector_count": "\(vectors.count)",
      ]
    )
    // Prompt tokens are not cheaply available from the embedding forward pass
    // without re-tokenizing, so report 0 per the Phase 2 contract.
    return [
      .vectors(requestID: request.requestID, dims: dims, payload: payload),
      .usage(requestID: request.requestID, promptTokens: 0, completionTokens: 0),
      .done(requestID: request.requestID),
    ]
  }

  private func recordRequestSpan(
    request: BackendRequest,
    startedAt: Date,
    startedNanoseconds: UInt64,
    outcome: String,
    attributes: [String: String]
  ) {
    let finishedNanoseconds = DispatchTime.now().uptimeNanoseconds
    SwiftLMMetrics.sink.recordRequestSpan(
      name: "embedding.request",
      modelID: modelPath,
      modelKind: "embedding",
      requestID: request.requestID,
      startedAt: startedAt,
      durationMilliseconds: Double(finishedNanoseconds - startedNanoseconds) / 1_000_000,
      attributes: attributes.merging(["outcome": outcome]) { current, _ in current }
    )
  }
}
