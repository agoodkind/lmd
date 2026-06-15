//
//  VideoFrameCodec.swift
//  LMDServeSupport
//
//  Serializes a video `BackendChatResult` into the broker-facing `BackendFrame`
//  sequence and reconstructs it on the broker side, so the model host and the
//  broker adapter share one codec and the rendered HTTP bytes stay identical to
//  the in-process path. The host renders generation into the existing SSE /
//  buffered shape, the codec carries those exact bytes over XPC, and the broker
//  rebuilds the same `BackendChatResult` the chat path already knows how to
//  render. A failure is carried as one `failed` frame whose message is a typed
//  envelope so the broker's existing catch ladder maps it to the same HTTP
//  status the in-process backend produced.
//

import Foundation
import SwiftLMHostProtocol

/// How a video result was shaped before serialization. The broker rebuilds the
/// matching `BackendChatResult` case from this header.
enum VideoResultShape: String, Codable, Sendable {
  case buffered
  case streaming
}

/// The first `chunk` frame of a video response. Carries the HTTP envelope the
/// broker needs to rebuild the result; the body bytes follow in later `chunk`
/// frames. Streaming bodies already include the terminal `[DONE]` line, so the
/// rebuilt streaming result does not re-append one.
struct VideoResultHeader: Codable, Sendable {
  let shape: VideoResultShape
  let statusCode: Int
  let contentType: String
}

/// The category of a video failure, preserved across XPC so the broker can
/// rethrow the same typed error the in-process backend threw and reach the same
/// status code. `generic` carries any other error's text verbatim.
enum VideoFailureCategory: String, Codable, Sendable {
  case notConfigured
  case modelMissingVideoSamplingFPS
  case requestBuild
  case generic
}

/// The typed failure envelope encoded into a `failed` frame's message.
struct VideoFailureEnvelope: Codable, Sendable {
  let category: VideoFailureCategory
  let message: String
  /// Present only for `modelMissingVideoSamplingFPS`.
  let modelID: String?
}

/// Errors the broker adapter raises when the host's frame sequence does not
/// match the codec contract.
public enum VideoFrameCodecError: Error, Equatable {
  /// The frame stream ended before the header `chunk`.
  case missingHeader
  /// The header `chunk` payload could not be decoded.
  case malformedHeader
}

// MARK: - FrameCollector

/// Collects frames from `VideoFrameCodec.stream` into an ordered array. The
/// codec calls `append` sequentially from one task, and the lock keeps the type
/// `Sendable` so it can be captured by the `@Sendable` send closure.
private final class FrameCollector: @unchecked Sendable {
  private let lock = NSLock()
  private var storage: [BackendFrame] = []

  func append(_ frame: BackendFrame) {
    lock.lock()
    defer { lock.unlock() }
    storage.append(frame)
  }

  var frames: [BackendFrame] {
    lock.lock()
    defer { lock.unlock() }
    return storage
  }
}

public enum VideoFrameCodec {
  /// One JSON encoder reused for the header and failure envelopes. Sorted keys
  /// keep the header bytes deterministic, which matters only for tests.
  private static let encoder: JSONEncoder = {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return encoder
  }()

  private static let decoder = JSONDecoder()

  /// Serialize a successful video result by handing each frame to `send` as it
  /// is produced: one header `chunk`, the body `chunk`s, then `done`. A streaming
  /// result forwards one chunk per generated event while generation runs, so the
  /// host emits tokens to the broker incrementally; a buffered result carries the
  /// whole body in one chunk. The frame shape is the contract `decode` reads back.
  @preconcurrency
  public static func stream(
    result: BackendChatResult,
    requestID: UUID,
    send: @Sendable (BackendFrame) -> Void
  ) async throws {
    switch result {
    case .buffered(let statusCode, let contentType, let body):
      let header = VideoResultHeader(
        shape: .buffered, statusCode: statusCode, contentType: contentType)
      send(.chunk(requestID: requestID, data: try encoder.encode(header)))
      send(.chunk(requestID: requestID, data: body))
      send(.done(requestID: requestID))
    case .streaming(let statusCode, let contentType, let events, let appendDoneFrame, _):
      let header = VideoResultHeader(
        shape: .streaming, statusCode: statusCode, contentType: contentType)
      send(.chunk(requestID: requestID, data: try encoder.encode(header)))
      // Render each event to its exact SSE bytes, the same bytes the in-process
      // path streams to the client, so the broker can replay them verbatim.
      for try await event in events {
        send(.chunk(requestID: requestID, data: try encodeBackendStreamEvent(event)))
      }
      if appendDoneFrame {
        send(.chunk(requestID: requestID, data: backendDoneFrame()))
      }
      send(.done(requestID: requestID))
    }
  }

  /// Serialize a successful video result into the frame sequence the broker reads
  /// back, collected into an array. The frames are exactly those `stream`
  /// produces, in order.
  public static func encode(
    result: BackendChatResult,
    requestID: UUID
  ) async throws -> [BackendFrame] {
    let collector = FrameCollector()
    try await stream(result: result, requestID: requestID) { collector.append($0) }
    return collector.frames
  }

  /// Decode the leading header `chunk` the host sends first. The broker's
  /// streaming path reads it to learn the response envelope before it forwards
  /// the body chunks.
  static func decodeHeader(_ data: Data) -> VideoResultHeader? {
    do {
      return try decoder.decode(VideoResultHeader.self, from: data)
    } catch {
      // A header that does not decode is reported by the caller as a malformed
      // header; recover here by returning nil.
      return nil
    }
  }

  /// Map a thrown serving error into one `failed` frame whose message is the
  /// typed envelope the broker decodes back into the original error category.
  public static func encodeFailure(_ error: Error, requestID: UUID) -> BackendFrame {
    let envelope: VideoFailureEnvelope
    switch error {
    case VideoChatBackendError.notConfigured:
      envelope = VideoFailureEnvelope(
        category: .notConfigured,
        message: VideoChatBackendError.notConfigured.description,
        modelID: nil
      )
    case VideoChatBackendError.modelMissingVideoSamplingFPS(let modelID):
      envelope = VideoFailureEnvelope(
        category: .modelMissingVideoSamplingFPS,
        message: VideoChatBackendError.modelMissingVideoSamplingFPS(modelID: modelID).description,
        modelID: modelID
      )
    case let buildError as VideoChatRequestBuildError:
      envelope = VideoFailureEnvelope(
        category: .requestBuild, message: buildError.description, modelID: nil)
    default:
      envelope = VideoFailureEnvelope(
        category: .generic, message: "\(error)", modelID: nil)
    }
    let message = (try? encoder.encode(envelope)).flatMap { String(data: $0, encoding: .utf8) }
    return .failed(requestID: requestID, message: message ?? "\(error)")
  }

  /// Decode a `failed` frame's message back into the original typed error, so
  /// the broker's chat-path catch ladder produces the same HTTP status. A
  /// message that is not a typed envelope (an older host or a non-codec sender)
  /// surfaces as a generic server failure carrying the raw text.
  static func decodeFailure(message: String) -> Error {
    guard let data = message.data(using: .utf8),
      let envelope = try? decoder.decode(VideoFailureEnvelope.self, from: data)
    else {
      return ModelServerVideoChatError.hostFailed(message: message)
    }
    switch envelope.category {
    case .notConfigured:
      return VideoChatBackendError.notConfigured
    case .modelMissingVideoSamplingFPS:
      return VideoChatBackendError.modelMissingVideoSamplingFPS(
        modelID: envelope.modelID ?? "")
    case .requestBuild:
      return decodeRequestBuildError(envelope.message)
    case .generic:
      return ModelServerVideoChatError.hostFailed(message: envelope.message)
    }
  }

  /// Recover the specific `VideoChatRequestBuildError` from its description so
  /// the broker maps it to HTTP 400 exactly as the in-process path did. An
  /// unrecognized description falls back to `invalidJSON`, which is still a 400.
  private static func decodeRequestBuildError(_ message: String) -> VideoChatRequestBuildError {
    let candidates: [VideoChatRequestBuildError] = [
      .invalidJSON,
      .missingMessages,
      .invalidMessage,
      .unsupportedContent,
      .noVideoContent,
      .invalidMaxTokens,
      .invalidTemperature,
    ]
    for candidate in candidates where candidate.description == message {
      return candidate
    }
    if message.hasPrefix("video chat message role is not supported: ") {
      let role = String(message.dropFirst("video chat message role is not supported: ".count))
      return .unsupportedRole(role)
    }
    return .invalidJSON
  }

  /// Read a video host's frame stream and rebuild the `BackendChatResult`. The
  /// first `chunk` is the header; subsequent `chunk`s are body bytes; `done`
  /// ends the request and `failed` raises the decoded typed error. For a
  /// streaming result the body bytes already include the `[DONE]` line, so the
  /// rebuilt result sets `appendDoneFrame: false`.
  static func decode(
    frames: AsyncThrowingStream<BackendFrame, Error>
  ) async throws -> BackendChatResult {
    var iterator = frames.makeAsyncIterator()
    var header: VideoResultHeader?
    var bodyChunks: [Data] = []
    while let frame = try await iterator.next() {
      switch frame {
      case .chunk(_, let data):
        if header == nil {
          guard let decoded = try? decoder.decode(VideoResultHeader.self, from: data) else {
            throw VideoFrameCodecError.malformedHeader
          }
          header = decoded
        } else {
          bodyChunks.append(data)
        }
      case .failed(_, let message):
        throw decodeFailure(message: message)
      case .done:
        guard let header else {
          throw VideoFrameCodecError.missingHeader
        }
        return rebuild(header: header, bodyChunks: bodyChunks)
      default:
        continue
      }
    }
    guard let header else {
      throw VideoFrameCodecError.missingHeader
    }
    return rebuild(header: header, bodyChunks: bodyChunks)
  }

  private static func rebuild(header: VideoResultHeader, bodyChunks: [Data]) -> BackendChatResult {
    switch header.shape {
    case .buffered:
      var body = Data()
      for chunk in bodyChunks {
        body.append(chunk)
      }
      return .buffered(
        statusCode: header.statusCode, contentType: header.contentType, body: body)
    case .streaming:
      let events = AsyncThrowingStream<BackendStreamEvent, Error> { continuation in
        for chunk in bodyChunks {
          continuation.yield(.rawBytes(chunk))
        }
        continuation.finish()
      }
      return .streaming(
        statusCode: header.statusCode,
        contentType: header.contentType,
        events: events,
        appendDoneFrame: false,
        lifetimeToken: nil
      )
    }
  }
}
