import Foundation
import Nimble
import SwiftLMHostProtocol
import XCTest

@testable import LMDServeSupport

/// Round-trips a video `BackendChatResult` through the codec to prove the broker
/// reconstructs the same HTTP envelope and body bytes the host serialized, and
/// that typed failures survive the `failed`-frame envelope.
final class VideoFrameCodecTests: XCTestCase {
  private let requestID = UUID()

  func testBufferedResultRoundTripsBytesAndEnvelope() async throws {
    let body = Data(#"{"object":"chat.completion","choices":[]}"#.utf8)
    let frames = try await VideoFrameCodec.encode(
      result: .buffered(statusCode: 200, contentType: "application/json", body: body),
      requestID: requestID
    )
    let result = try await VideoFrameCodec.decode(frames: stream(frames))

    guard case .buffered(let statusCode, let contentType, let decodedBody) = result else {
      fail("expected buffered result")
      return
    }
    expect(statusCode) == 200
    expect(contentType) == "application/json"
    expect(decodedBody) == body
  }

  func testStreamingResultRoundTripsExactSSEBytesIncludingDone() async throws {
    let id = "chatcmpl-test"
    let created = 1
    let model = "video-model"
    let events = AsyncThrowingStream<BackendStreamEvent, Error> { continuation in
      continuation.yield(.role(id: id, created: created, model: model, role: "assistant"))
      continuation.yield(.content(id: id, created: created, model: model, content: "hi"))
      continuation.yield(
        .finish(id: id, created: created, model: model, finishReason: "stop", usage: nil))
      continuation.finish()
    }
    let frames = try await VideoFrameCodec.encode(
      result: .streaming(
        statusCode: 200,
        contentType: "text/event-stream",
        events: events,
        appendDoneFrame: true,
        lifetimeToken: nil
      ),
      requestID: requestID
    )

    // The reference bytes are exactly the body chunks the codec captured (every
    // chunk after the header), so the round-trip proves the broker replays the
    // host's serialized SSE verbatim, with the terminal [DONE] line present.
    var expected = Data()
    for frame in frames.dropFirst() {
      if case .chunk(_, let bytes) = frame {
        expected.append(bytes)
      }
    }
    expect(String(data: expected, encoding: .utf8)?.contains("data: [DONE]\n\n") ?? false) == true

    let result = try await VideoFrameCodec.decode(frames: stream(frames))
    guard case .streaming(let statusCode, let contentType, let rebuilt, let appendDone, _) = result
    else {
      fail("expected streaming result")
      return
    }
    expect(statusCode) == 200
    expect(contentType) == "text/event-stream"
    // The host already serialized [DONE]; the broker must not re-append one.
    expect(appendDone) == false

    var assembled = Data()
    for try await event in rebuilt {
      guard case .rawBytes(let bytes) = event else {
        fail("expected rawBytes events")
        return
      }
      assembled.append(bytes)
    }
    expect(assembled) == expected
  }

  func testNotConfiguredFailureRoundTripsToTypedError() async {
    let frame = VideoFrameCodec.encodeFailure(
      VideoChatBackendError.notConfigured, requestID: requestID)
    await assertDecodeThrows(frame) { error in
      expect(error as? VideoChatBackendError) == .notConfigured
    }
  }

  func testModelMissingSamplingFPSFailureRoundTripsWithModelID() async {
    let frame = VideoFrameCodec.encodeFailure(
      VideoChatBackendError.modelMissingVideoSamplingFPS(modelID: "/m"), requestID: requestID)
    await assertDecodeThrows(frame) { error in
      expect(error as? VideoChatBackendError) == .modelMissingVideoSamplingFPS(modelID: "/m")
    }
  }

  func testRequestBuildFailureRoundTripsToSpecificCase() async {
    let frame = VideoFrameCodec.encodeFailure(
      VideoChatRequestBuildError.noVideoContent, requestID: requestID)
    await assertDecodeThrows(frame) { error in
      expect(error as? VideoChatRequestBuildError) == .noVideoContent
    }
  }

  func testUnsupportedRoleFailureRoundTripsWithRole() async {
    let frame = VideoFrameCodec.encodeFailure(
      VideoChatRequestBuildError.unsupportedRole("tool"), requestID: requestID)
    await assertDecodeThrows(frame) { error in
      expect(error as? VideoChatRequestBuildError) == .unsupportedRole("tool")
    }
  }

  func testGenericFailureRoundTripsAsHostFailed() async {
    struct Boom: Error {}
    let frame = VideoFrameCodec.encodeFailure(Boom(), requestID: requestID)
    await assertDecodeThrows(frame) { error in
      guard
        case ModelServerVideoChatError.hostFailed(let message)? = error
          as? ModelServerVideoChatError
      else {
        return fail("expected hostFailed, got \(error)")
      }
      expect(message.contains("Boom")) == true
    }
  }

  func testDecodeThrowsWhenHeaderMissing() async {
    let frames: [BackendFrame] = [.done(requestID: requestID)]
    do {
      _ = try await VideoFrameCodec.decode(frames: stream(frames))
      fail("expected missingHeader")
    } catch let error as VideoFrameCodecError {
      expect(error) == .missingHeader
    } catch {
      fail("expected VideoFrameCodecError, got \(error)")
    }
  }

  private func assertDecodeThrows(
    _ frame: BackendFrame,
    _ assertion: (Error) -> Void
  ) async {
    do {
      _ = try await VideoFrameCodec.decode(frames: stream([frame]))
      fail("expected decode to throw")
    } catch {
      assertion(error)
    }
  }

  private func stream(_ frames: [BackendFrame]) -> AsyncThrowingStream<BackendFrame, Error> {
    AsyncThrowingStream { continuation in
      for frame in frames {
        continuation.yield(frame)
      }
      continuation.finish()
    }
  }
}
