//
//  VideoHost.swift
//  lmd-model-host
//
//  Serves VLM video chat requests in-process. The host reuses the broker's
//  former `InProcessVLMVideoChatBackend` loading and inference logic, decodes the
//  verbatim OpenAI chat-with-video body the broker forwards, runs frame sampling
//  and generation, and serializes the resulting `BackendChatResult` into the
//  broker-facing frame sequence with `VideoFrameCodec`, so the rendered HTTP
//  bytes match the in-process path exactly. Any error becomes one typed `failed`
//  frame the broker maps back to the same HTTP status.
//

import Dispatch
import Foundation
import LMDServeSupport
import SwiftLMCore
import SwiftLMHostProtocol
import SwiftLMMetrics

/// In-process video serving for `lmd-model-host`. Holds the loaded VLM backend
/// and the reconstructed model descriptor whose capabilities carry the sampling
/// rate the broker passed in argv.
actor VideoHost {
  private let descriptor: ModelDescriptor
  private let backend = InProcessVLMVideoChatBackend()
  // mlx 0.32 keeps Metal command encoders in thread-local storage, so the model
  // load and every forward must run on one fixed OS thread or a later request
  // faults with "no Stream(gpu, 0) in current thread". Pin all GPU work here.
  private let gpuThread = GPUThread()

  init(modelPath: String, videoSamplingFPS: Double?) {
    // The catalog keys a model's identity on its real path, so `id` and `path`
    // are both the model path here. Video routes only on a chat-kind model that
    // advertises video, so rebuild those capabilities for the backend's guard.
    self.descriptor = ModelDescriptor(
      id: modelPath,
      displayName: (modelPath as NSString).lastPathComponent,
      path: modelPath,
      kind: .chat,
      capabilities: ModelCapabilities(
        text: true, vision: true, video: true, videoSamplingFPS: videoSamplingFPS)
    )
  }

  /// Serve one video request, handing each frame to `send` as it is produced.
  /// A streaming request forwards one frame per generated token while generation
  /// runs, so the broker receives a token's text the moment it decodes; a
  /// non-streaming request sends the buffered body. Decoding, frame sampling,
  /// generation, and serialization all happen here; any thrown error becomes one
  /// typed `failed` frame.
  func serve(
    _ request: BackendRequest,
    send: @escaping @Sendable (BackendFrame) -> Void
  ) async {
    await SwiftLMMetrics.withRequestSpan(
      "video.request",
      modelID: descriptor.id,
      modelKind: "video",
      requestID: request.requestID
    ) {
      await serveInSpan(for: request, send: send)
    }
  }

  private func serveInSpan(
    for request: BackendRequest,
    send: @escaping @Sendable (BackendFrame) -> Void
  ) async {
    let requestStartedAt = Date()
    let requestStartedNanoseconds = DispatchTime.now().uptimeNanoseconds
    let routeRequest = VideoChatRouteRequest(
      model: descriptor,
      endpoint: .chatCompletions,
      bodyData: request.openAIBody,
      wantsStream: request.stream,
      videos: [],
      requestID: request.requestID
    )
    do {
      // The backend pins the model load and generation to its own GPU thread, so
      // the result's event stream can be drained outside this preference. The
      // preference covers frame sampling and the load for the buffered path.
      let result = try await withTaskExecutorPreference(gpuThread) {
        try await backend.complete(routeRequest)
      }
      try await VideoFrameCodec.stream(
        result: result, requestID: request.requestID, send: send)
      recordRequestSpan(
        request: request,
        startedAt: requestStartedAt,
        startedNanoseconds: requestStartedNanoseconds,
        outcome: "completed",
        attributes: ["stream": "\(request.stream)"]
      )
    } catch {
      send(VideoFrameCodec.encodeFailure(error, requestID: request.requestID))
      recordRequestSpan(
        request: request,
        startedAt: requestStartedAt,
        startedNanoseconds: requestStartedNanoseconds,
        outcome: "failed",
        attributes: ["error": "\(error)", "stream": "\(request.stream)"]
      )
    }
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
      name: "video.request",
      modelID: descriptor.id,
      modelKind: "video",
      requestID: request.requestID,
      startedAt: startedAt,
      durationMilliseconds: Double(finishedNanoseconds - startedNanoseconds) / 1_000_000,
      attributes: attributes.merging(["outcome": outcome]) { current, _ in current }
    )
  }
}
