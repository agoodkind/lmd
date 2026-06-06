//
//  XPCVideoChatBackend.swift
//  LMDServeSupport
//
//  Adapts a `ModelServer` (a VLM video model host reached over XPC) to the
//  `VideoChatBackend` protocol the chat path already calls. The broker stops
//  running video inference in-process; this adapter spawns one host per model,
//  forwards the verbatim OpenAI body, and rebuilds the streamed frames into the
//  same `BackendChatResult` the in-process backend produced, so the external
//  chat-with-video request and response shape is unchanged. The router collapse
//  onto `ModelServer` is a later phase; until then this adapter owns the host
//  lifecycle for video the same way `XPCEmbeddingBackend` does for embedding.
//

import Foundation
import SwiftLMCore
import SwiftLMHostProtocol
import SwiftLMRuntime

/// Why a video request over XPC could not produce a result through the adapter
/// rather than through a typed host failure.
public enum XPCVideoChatBackendError: Error, Equatable {
  /// The host reported failure for this request with a non-typed message.
  case hostFailed(message: String)
}

/// Spawns a video model host, registers it so its dial-in binds, and waits for
/// the model to be resident. Returns the bound `ModelServer`. The broker injects
/// the concrete `XPCModelServer` construction and `HostServerStore` registration
/// here; tests inject a fake server and no-op registry.
public typealias VideoHostLauncher = @Sendable (ModelDescriptor) async throws -> ModelServer

public actor XPCVideoChatBackend: VideoChatBackend {
  private let launch: VideoHostLauncher
  // One live host per model id, spawned lazily on the first request and reused
  // for later requests until eviction drops it. Keyed on the same model id the
  // host registry and spawn-token map use.
  private var servers: [String: ModelServer] = [:]

  public init(launch: @escaping VideoHostLauncher) {
    self.launch = launch
  }

  public func complete(_ request: VideoChatRouteRequest) async throws -> BackendChatResult {
    // The dispatch rules already proved this model advertises video; mirror the
    // in-process backend's guard so a video-capable model with no sampling rate
    // reaches the same typed error and HTTP status.
    guard request.model.capabilities.videoSamplingFPS != nil else {
      throw VideoChatBackendError.modelMissingVideoSamplingFPS(modelID: request.model.id)
    }
    let server = try await server(for: request.model)
    let backendRequest = BackendRequest(
      requestID: UUID(),
      kind: .video,
      openAIBody: request.bodyData,
      stream: request.wantsStream
    )
    return try await VideoFrameCodec.decode(frames: server.send(backendRequest))
  }

  private func server(for model: ModelDescriptor) async throws -> ModelServer {
    if let server = servers[model.id] {
      return server
    }
    let server = try await launch(model)
    servers[model.id] = server
    return server
  }
}
