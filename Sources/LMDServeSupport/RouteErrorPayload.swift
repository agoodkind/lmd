//
//  RouteErrorMapping.swift
//  LMDServeSupport
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-06-26.
//  Copyright © 2026, all rights reserved.
//

import SwiftLMControl
import SwiftLMRuntime

private let httpStatusBadRequest = 400
private let httpStatusConflict = 409
private let httpStatusInternalServerError = 500
private let httpStatusTooManyRequests = 429
private let httpStatusServiceUnavailable = 503

public struct RouteErrorPayload: Equatable, Sendable {
  public let statusCode: Int
  public let message: String
  public let type: String

  public init(statusCode: Int, message: String, type: String) {
    self.statusCode = statusCode
    self.message = message
    self.type = type
  }
}

private func servicePausedMessage(reason: String) -> String {
  "service paused to preserve battery (\(reason))"
}

public func chatRouteErrorPayload(
  _ error: ModelRouter.RouteError,
  modelDisplayName: String
) -> RouteErrorPayload {
  switch error {
  case .insufficientHeadroom:
    return RouteErrorPayload(
      statusCode: httpStatusServiceUnavailable,
      message: "not enough free memory to load \(modelDisplayName) while keeping the reserve",
      type: "capacity_exceeded"
    )
  case .backendLaunchFailed:
    return RouteErrorPayload(
      statusCode: httpStatusServiceUnavailable,
      message: "failed to launch model \(modelDisplayName)",
      type: "launch_failed"
    )
  case .concurrencyLimitExceeded(_, let limit):
    return RouteErrorPayload(
      statusCode: httpStatusTooManyRequests,
      message: "chat concurrency limit reached (\(limit))",
      type: "capacity_exceeded"
    )
  case .loadConfigConflict:
    return RouteErrorPayload(
      statusCode: httpStatusConflict,
      message: "model is busy with a different load configuration",
      type: "load_config_conflict"
    )
  case .wrongKindForChat:
    return RouteErrorPayload(
      statusCode: httpStatusBadRequest,
      message: "model is an embedding model; use POST /v1/embeddings",
      type: "invalid_request_error"
    )
  case .wrongKindForEmbedding:
    return RouteErrorPayload(
      statusCode: httpStatusInternalServerError,
      message: "router configuration error",
      type: "internal_error"
    )
  case .powerPaused(let reason):
    return RouteErrorPayload(
      statusCode: httpStatusServiceUnavailable,
      message: servicePausedMessage(reason: reason),
      type: "service_paused"
    )
  case .modelYielding:
    return RouteErrorPayload(
      statusCode: httpStatusServiceUnavailable,
      message: "model yielded memory to a higher-priority load; retry shortly",
      type: "model_yielding"
    )
  case .queueDrained:
    return RouteErrorPayload(
      statusCode: httpStatusServiceUnavailable,
      message: "model was unloaded while request was queued; retry shortly",
      type: "model_unloaded"
    )
  }
}

public func embeddingRouteErrorPayload(_ error: ModelRouter.RouteError) -> RouteErrorPayload {
  switch error {
  case .insufficientHeadroom:
    return RouteErrorPayload(
      statusCode: httpStatusServiceUnavailable,
      message: "not enough free memory to load embedding model while keeping the reserve",
      type: "capacity_exceeded"
    )
  case .backendLaunchFailed:
    return RouteErrorPayload(
      statusCode: httpStatusServiceUnavailable,
      message: "failed to load embedding model",
      type: "launch_failed"
    )
  case .concurrencyLimitExceeded(_, let limit):
    return RouteErrorPayload(
      statusCode: httpStatusTooManyRequests,
      message: "embedding concurrency limit reached (\(limit))",
      type: "capacity_exceeded"
    )
  case .loadConfigConflict:
    return RouteErrorPayload(
      statusCode: httpStatusConflict,
      message: "embedding model is busy with a different load configuration",
      type: "load_config_conflict"
    )
  case .wrongKindForChat:
    return RouteErrorPayload(
      statusCode: httpStatusBadRequest,
      message: "model is an embedding model; use POST /v1/embeddings",
      type: "invalid_request_error"
    )
  case .wrongKindForEmbedding:
    return RouteErrorPayload(
      statusCode: httpStatusBadRequest,
      message: "model is not an embedding model",
      type: "invalid_request_error"
    )
  case .powerPaused(let reason):
    return RouteErrorPayload(
      statusCode: httpStatusServiceUnavailable,
      message: servicePausedMessage(reason: reason),
      type: "service_paused"
    )
  case .modelYielding:
    return RouteErrorPayload(
      statusCode: httpStatusServiceUnavailable,
      message: "embedding model yielded memory to a higher-priority load; retry shortly",
      type: "model_yielding"
    )
  case .queueDrained:
    return RouteErrorPayload(
      statusCode: httpStatusServiceUnavailable,
      message: "embedding model was unloaded while request was queued; retry shortly",
      type: "model_unloaded"
    )
  }
}

public func videoRouteErrorPayload(_ error: ModelRouter.RouteError) -> RouteErrorPayload {
  switch error {
  case .powerPaused(let reason):
    return RouteErrorPayload(
      statusCode: httpStatusServiceUnavailable,
      message: servicePausedMessage(reason: reason),
      type: "service_paused"
    )
  case .insufficientHeadroom,
    .backendLaunchFailed,
    .concurrencyLimitExceeded,
    .loadConfigConflict,
    .queueDrained,
    .wrongKindForChat,
    .wrongKindForEmbedding,
    .modelYielding:
    return RouteErrorPayload(
      statusCode: httpStatusServiceUnavailable,
      message: "video chat backend failed: \(error)",
      type: "video_backend_failed"
    )
  }
}

public func brokerServicePausedError(reason: String) -> BrokerError {
  BrokerError(kind: .servicePaused, message: servicePausedMessage(reason: reason))
}

public func xpcEmbeddingRouteBrokerError(_ error: Error) -> BrokerError {
  if case let routeError as ModelRouter.RouteError = error,
    case let .powerPaused(reason) = routeError
  {
    return brokerServicePausedError(reason: reason)
  }
  return BrokerError(kind: .embeddingFailed, message: "route: \(error)")
}
