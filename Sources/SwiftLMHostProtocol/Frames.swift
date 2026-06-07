//
//  Frames.swift
//  SwiftLMHostProtocol
//
//  Wire types shared by the broker (lmd-serve) and the model host
//  (lmd-model-host) over the broker's `io.goodkind.lmd.host` Mach service.
//  Pure Codable. No platform or MLX dependencies so both ends link it cheaply.
//

import Foundation

/// The kind of work a model host process serves. Mirrors the routing kinds
/// the broker already distinguishes.
public enum BackendKind: String, Codable, Sendable {
  case chat
  case embedding
  case video
}

/// Battery throttle level on the wire. Mirrors `SwiftLMCore.PowerThrottleLevel`
/// without depending on it, so this module stays free of MLX and SwiftLMCore.
/// The broker maps `PowerThrottleLevel` to this before sending; the host maps it
/// back when applying it to its in-process backend.
public enum ThrottleLevel: String, Codable, Sendable, Equatable {
  case none
  case mild
  case hard
}

/// A broker-to-host control message that is not request work. Carried in
/// `HostInbound.control` so the host can act on it out of band from serving.
public enum HostControl: Codable, Sendable, Equatable {
  /// Apply a battery throttle level to the host's in-process backend so it can
  /// shrink its GPU cache, matching the in-process router behavior.
  case applyPowerThrottle(ThrottleLevel)
}

/// Everything the broker sends a host over its bound session: either request
/// work or an out-of-band control message. The host decodes this single
/// envelope and routes by case.
public enum HostInbound: Codable, Sendable, Equatable {
  case request(BackendRequest)
  case control(HostControl)
}

/// One unit of work the broker sends to a model host over its bound session.
public struct BackendRequest: Codable, Sendable, Equatable {
  public let requestID: UUID
  public let kind: BackendKind
  /// The exact OpenAI JSON body the external client sent, forwarded verbatim.
  public let openAIBody: Data
  public let stream: Bool
  /// The upstream OpenAI endpoint path for chat requests. nil for embedding and
  /// video requests, whose endpoint is implied by their kind.
  public let endpointPath: String?
  /// Broker-supplied HTTP headers to preserve when the host proxies a chat
  /// request to the child SwiftLM server. Empty for non-chat requests.
  public let headers: [String: String]

  public init(
    requestID: UUID,
    kind: BackendKind,
    openAIBody: Data,
    stream: Bool,
    endpointPath: String? = nil,
    headers: [String: String] = [:]
  ) {
    self.requestID = requestID
    self.kind = kind
    self.openAIBody = openAIBody
    self.stream = stream
    self.endpointPath = endpointPath
    self.headers = headers
  }
}

/// One frame a model host sends back to the broker. A request's frames are
/// correlated by `requestID`; lifecycle frames (`hello`, `ready`, `stats`,
/// `metricsSnapshot`) carry no request id.
public enum BackendFrame: Codable, Sendable, Equatable {
  /// First frame after dial-in. Carries the per-spawn token the broker wrote
  /// to the child's stdin, so the broker binds this session to the child it
  /// spawned.
  case hello(spawnToken: String)
  /// The model is resident and the host is ready to serve requests.
  case ready
  /// HTTP response metadata for a chat request before body chunks follow.
  case responseStarted(requestID: UUID, statusCode: Int, contentType: String)
  /// One streamed output chunk (an OpenAI SSE line for chat and video).
  case chunk(requestID: UUID, data: Data)
  /// Embedding vectors as a contiguous little-endian Float32 blob. The vector
  /// count is `payload.count / 4 / dims`.
  case vectors(requestID: UUID, dims: Int, payload: Data)
  /// Token accounting for one request.
  case usage(requestID: UUID, promptTokens: Int, completionTokens: Int)
  /// Terminal success for one request.
  case done(requestID: UUID)
  /// Terminal failure for one request.
  case failed(requestID: UUID, message: String)
  /// Live memory footprint of this host process.
  case stats(rssBytes: Int64, gpuActiveBytes: Int64, gpuCacheBytes: Int64)
  /// A SwiftLMMetrics JSON snapshot pushed on a fixed interval.
  case metricsSnapshot(Data)
}

/// The most recent memory figures a host reported. Broker-side mirror of the
/// `stats` frame for the router's eviction logic.
public struct BackendStats: Codable, Sendable, Equatable {
  public let rssBytes: Int64
  public let gpuActiveBytes: Int64
  public let gpuCacheBytes: Int64

  public init(rssBytes: Int64, gpuActiveBytes: Int64, gpuCacheBytes: Int64) {
    self.rssBytes = rssBytes
    self.gpuActiveBytes = gpuActiveBytes
    self.gpuCacheBytes = gpuCacheBytes
  }
}
