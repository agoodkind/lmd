//
//  RouteErrorMappingTests.swift
//  LMDServeTests
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-06-26.
//  Copyright © 2026, all rights reserved.
//

import Foundation
import Nimble
import SwiftLMControl
import SwiftLMRuntime
import XCTest

@testable import LMDServeSupport

private struct DecodedErrorResult: Equatable {
  let statusCode: Int
  let type: String
  let message: String
}

final class RouteErrorMappingTests: XCTestCase {
  func testChatPowerPauseMapsToServicePausedPayload() {
    let payload = chatRouteErrorPayload(
      .powerPaused(reason: "low_power_mode"),
      modelDisplayName: "chat-model"
    )

    expect(payload.statusCode) == 503
    expect(payload.type) == "service_paused"
    expect(payload.message) == "service paused to preserve battery (low_power_mode)"
  }

  func testEmbeddingPowerPauseMapsToServicePausedPayload() {
    let payload = embeddingRouteErrorPayload(.powerPaused(reason: "low_power_mode"))

    expect(payload.statusCode) == 503
    expect(payload.type) == "service_paused"
    expect(payload.message) == "service paused to preserve battery (low_power_mode)"
  }

  func testEmbeddingQueueDrainedMapsToModelUnloadedPayload() {
    let payload = embeddingRouteErrorPayload(.queueDrained(modelID: "embed"))

    expect(payload.statusCode) == 503
    expect(payload.type) == "model_unloaded"
    expect(payload.message) == "embedding model was unloaded while request was queued; retry shortly"
  }

  func testChatRoutePayloadBuildsServicePausedEnvelope() throws {
    let payload = chatRouteErrorPayload(
      .powerPaused(reason: "low_power_mode"),
      modelDisplayName: "chat-model"
    )
    let result = backendErrorResult(
      statusCode: payload.statusCode,
      message: payload.message,
      type: payload.type
    )

    let decoded = try decodeErrorResult(result)
    expect(decoded.statusCode) == 503
    expect(decoded.type) == "service_paused"
    expect(decoded.message) == "service paused to preserve battery (low_power_mode)"
  }

  func testXPCEmbeddingPowerPauseMapsToServicePausedBrokerError() {
    let error = xpcEmbeddingRouteBrokerError(
      ModelRouter.RouteError.powerPaused(reason: "low_power_mode")
    )

    expect(error.kind) == .servicePaused
    expect(error.message) == "service paused to preserve battery (low_power_mode)"
  }

  private func decodeErrorResult(
    _ result: BackendChatResult
  ) throws -> DecodedErrorResult {
    guard case let .buffered(statusCode, _, body) = result else {
      fail("expected buffered error result")
      throw NSError(domain: "RouteErrorMappingTests", code: 1)
    }
    guard
      let json = try JSONSerialization.jsonObject(with: body) as? [String: Any],
      let error = json["error"] as? [String: Any],
      let type = error["type"] as? String,
      let message = error["message"] as? String
    else {
      fail("expected error JSON body")
      throw NSError(domain: "RouteErrorMappingTests", code: 2)
    }
    return DecodedErrorResult(statusCode: statusCode, type: type, message: message)
  }
}
