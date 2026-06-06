//
//  ModelServer.swift
//  SwiftLMRuntime
//
//  The one abstraction the router holds for a loaded model. The router never
//  knows whether it backs chat, embedding, or video; it spawns, waits, sends,
//  reads memory, and shuts down. The concrete `XPCModelServer` lives in
//  lmd-serve and is injected through the existing spawner closure.
//

import Foundation
import SwiftLMCore
import SwiftLMHostProtocol

public enum ModelServerError: Error, Sendable {
  case spawnFailed(modelID: String, message: String)
  case notReady(modelID: String)
  case sessionLost(modelID: String)
}

public protocol ModelServer: AnyObject, Sendable {
  var modelID: String { get }
  /// Admission estimate used before the model is resident.
  var sizeBytes: Int64 { get }
  /// Launch the host process.
  func spawn() async throws
  /// Resolves when the host has reported `ready`.
  func waitReady() async throws
  /// Stream the frames for one request, correlated by `request.requestID`.
  func send(_ request: BackendRequest) -> AsyncThrowingStream<BackendFrame, Error>
  /// Most recent footprint the host reported.
  func stats() async -> BackendStats
  /// Forward a battery throttle level to the host as an out-of-band control
  /// message. The host applies it to its in-process backend so the GPU cache
  /// shrinks under battery pressure, matching the in-process router behavior.
  /// The default is a no-op for servers whose host manages no GPU cache.
  func applyPowerThrottle(_ level: ThrottleLevel)
  /// Cancel the session and SIGKILL the host, reclaiming its memory.
  func shutdown()
}

extension ModelServer {
  public func applyPowerThrottle(_ level: ThrottleLevel) {}
}
