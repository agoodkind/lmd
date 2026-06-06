//
//  XPCEmbeddingBackend.swift
//  LMDServeSupport
//
//  Adapts a `ModelServer` (an embedding model host reached over XPC) to the
//  `EmbeddingBackendProtocol` the router and HTTP handlers already speak. This
//  keeps `routeEmbeddingAndBegin`'s return type unchanged while the actual
//  forward pass runs in the helper process. The full router collapse onto
//  `ModelServer` is a later phase; until then this adapter is the seam.
//

import Foundation
import SwiftLMBackend
import SwiftLMCore
import SwiftLMHostProtocol
import SwiftLMRuntime

/// Why an embedding request over XPC could not produce vectors.
public enum XPCEmbeddingBackendError: Error, Equatable {
  /// The host reported failure for this request.
  case hostFailed(message: String)
  /// The frame stream ended without a `vectors` frame.
  case noVectorsReturned
}

public final class XPCEmbeddingBackend: EmbeddingBackendProtocol, @unchecked Sendable {
  private let server: ModelServer

  public var modelID: String { server.modelID }
  public var sizeBytes: Int64 { server.sizeBytes }

  public init(server: ModelServer) {
    self.server = server
  }

  /// Spawn the host process and wait for it to report the model resident.
  public func launch() async throws {
    try await server.spawn()
    try await server.waitReady()
  }

  /// Send one embeddings request and decode the single `vectors` frame the host
  /// returns. Drains the rest of the stream (`usage`, `done`) so the request is
  /// fully consumed. Throws on a `failed` frame or a stream that ends without
  /// vectors.
  public func embed(inputs: [String]) async throws -> [[Float]] {
    let body = try JSONSerialization.data(withJSONObject: ["input": inputs])
    let request = BackendRequest(
      requestID: UUID(),
      kind: .embedding,
      openAIBody: body,
      stream: false
    )
    var decoded: [[Float]]?
    for try await frame in server.send(request) {
      switch frame {
      case .vectors(_, let dims, let payload):
        decoded = try VectorBlob.decode(dims: dims, payload: payload)
      case .failed(_, let message):
        throw XPCEmbeddingBackendError.hostFailed(message: message)
      case .done:
        break
      default:
        break
      }
    }
    guard let decoded else {
      throw XPCEmbeddingBackendError.noVectorsReturned
    }
    return decoded
  }

  /// Cancel the session and SIGKILL the host, reclaiming its memory.
  public func shutdown() {
    server.shutdown()
  }

  /// Forward the battery throttle level to the embedding host over the control
  /// channel so its in-process MLX backend shrinks the allocator cache at `hard`
  /// and restores it otherwise. Restores the behavior the in-process backend had
  /// before embedding moved to the helper.
  public func applyPowerThrottle(_ level: PowerThrottleLevel) {
    let wire: ThrottleLevel
    switch level {
    case .none:
      wire = .none
    case .mild:
      wire = .mild
    case .hard:
      wire = .hard
    }
    server.applyPowerThrottle(wire)
  }
}
