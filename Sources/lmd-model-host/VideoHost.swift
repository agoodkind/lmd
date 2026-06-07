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

  /// Run one video request and return the frames to send back, in order.
  /// Decoding, frame sampling, generation, and serialization all happen here;
  /// any thrown error is mapped to a single typed `failed` frame.
  func frames(for request: BackendRequest) async -> [BackendFrame] {
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
      let result = try await backend.complete(routeRequest)
      let frames = try await VideoFrameCodec.encode(result: result, requestID: request.requestID)
      recordRequestSpan(
        request: request,
        startedAt: requestStartedAt,
        startedNanoseconds: requestStartedNanoseconds,
        outcome: "completed",
        attributes: ["stream": "\(request.stream)"]
      )
      return frames
    } catch {
      recordRequestSpan(
        request: request,
        startedAt: requestStartedAt,
        startedNanoseconds: requestStartedNanoseconds,
        outcome: "failed",
        attributes: ["error": "\(error)", "stream": "\(request.stream)"]
      )
      return [VideoFrameCodec.encodeFailure(error, requestID: request.requestID)]
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
    SnapshotSink.shared.recordRequestSpan(
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
