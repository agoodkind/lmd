//
//  VideoChatRoutingTests.swift
//  LMDServeTests
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-05-09.
//  Copyright © 2026, all rights reserved.
//

import Foundation
import Nimble
import SwiftLMCore
import XCTest

@testable import LMDServeSupport

private actor CompletionCounter {
  private(set) var value = 0

  func increment() {
    value += 1
  }

  func currentValue() -> Int {
    value
  }
}

final class VideoChatRoutingTests: XCTestCase {
  private var temporaryRoot: URL!

  override func setUpWithError() throws {
    try super.setUpWithError()
    temporaryRoot = FileManager.default.temporaryDirectory
      .appendingPathComponent(
        "LMDServeVideoChatRoutingTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(
      at: temporaryRoot,
      withIntermediateDirectories: true
    )
  }

  override func tearDownWithError() throws {
    if let temporaryRoot {
      try? FileManager.default.removeItem(at: temporaryRoot)
    }
    temporaryRoot = nil
    try super.tearDownWithError()
  }

  func testParsesLocalFileVideoURLMetadata() throws {
    let videoFile = try writeFile(named: "clip.mp4")
    let json = chatRequest(videoURL: videoFile.absoluteString, fps: 2.5, maxFrames: 48)

    let inspection = try inspectOpenAIVideoInputs(in: json)

    expect(inspection.containsVideo) == true
    expect(inspection.videos.count) == 1
    expect(inspection.videos[0].url) == URL(string: videoFile.absoluteString)
    expect(inspection.videos[0].fileURL) == videoFile.standardizedFileURL
    expect(inspection.videos[0].fps) == 2.5
    expect(inspection.videos[0].maxFrames) == 48
  }

  func testExplicitRequestFPSOverridesModelSamplingFPS() {
    expect(effectiveSamplingFPS(modelFPS: 2.0, requestFPS: 16.0)) == 16.0
    expect(effectiveSamplingFPS(modelFPS: 2.0, requestFPS: nil)) == 2.0
  }

  func testIgnoresTextOnlyMessages() throws {
    let json: [String: Any] = [
      "model": "model-a",
      "messages": [
        ["role": "user", "content": "summarize this"]
      ],
    ]

    let inspection = try inspectOpenAIVideoInputs(in: json)

    expect(inspection.containsVideo) == false
    expect(inspection.videos) == []
  }

  func testRejectsNonFileURLs() {
    assertVideoParseError(
      .unsupportedURLScheme("https"),
      json: chatRequest(videoURL: "https://localhost/video.mp4")
    )
    assertVideoParseError(
      .unsupportedURLScheme("data"),
      json: chatRequest(videoURL: "data:video/mp4;base64,AAAA")
    )
  }

  func testRejectsRelativeAndRemoteFileURLs() {
    assertVideoParseError(
      .relativeFileURL("file:clip.mp4"),
      json: chatRequest(videoURL: "file:clip.mp4")
    )
    assertVideoParseError(
      .nonLocalFileHost("example.com"),
      json: chatRequest(videoURL: "file://example.com/tmp/clip.mp4")
    )
  }

  func testRejectsMissingNonRegularAndUnsupportedFiles() throws {
    let missingFile = temporaryRoot.appendingPathComponent("missing.mp4")
    let textFile = try writeFile(named: "clip.txt")
    let directoryURL = temporaryRoot.appendingPathComponent("directory.mov", isDirectory: true)
    try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)

    assertVideoParseError(
      .fileNotFound(missingFile.path),
      json: chatRequest(videoURL: missingFile.absoluteString)
    )
    assertVideoParseError(
      .unsupportedExtension("txt"),
      json: chatRequest(videoURL: textFile.absoluteString)
    )
    assertVideoParseError(
      .notRegularFile(directoryURL.standardizedFileURL.path),
      json: chatRequest(videoURL: directoryURL.absoluteString)
    )
  }

  func testRejectsInvalidFPSAndMaxFrames() throws {
    let videoFile = try writeFile(named: "clip.mov")

    assertVideoParseError(
      .invalidFPS,
      json: chatRequest(videoURL: videoFile.absoluteString, fps: 0, maxFrames: 10)
    )
    assertVideoParseError(
      .invalidMaxFrames,
      json: chatRequest(videoURL: videoFile.absoluteString, fps: 1, maxFrames: 4_097)
    )
    assertVideoParseError(
      .invalidMaxFrames,
      json: chatRequest(videoURL: videoFile.absoluteString, fps: 1, maxFrames: 1.5)
    )
  }

  func testRouteDecisionPreservesTypedVideoMetadataForBackend() throws {
    let videoFile = try writeFile(named: "clip.webm")
    let json = chatRequest(videoURL: videoFile.absoluteString, fps: 1, maxFrames: 8)
    let inspection = try inspectOpenAIVideoInputs(in: json)
    let bodyData = try JSONSerialization.data(withJSONObject: json)
    let model = ModelDescriptor(
      id: "video-model",
      displayName: "Video Model",
      path: "/models/video-model",
      sizeBytes: 42,
      capabilities: .init(video: true, videoSamplingFPS: 2)
    )

    let decision = chatRoutingDecision(
      path: "/v1/chat/completions",
      bodyData: bodyData,
      model: model,
      wantsStream: false,
      videoInspection: inspection
    )

    guard case .videoBackend(let request) = decision else {
      fail("expected video backend route")
      return
    }
    expect(request.model.id) == "video-model"
    expect(request.endpoint) == .chatCompletions
    expect(request.bodyData) == bodyData
    expect(request.wantsStream) == false
    expect(request.videos) == inspection.videos
  }

  func testRouteDecisionKeepsTextOnlyRequestsOnSwiftLMProxy() {
    let model = ModelDescriptor(
      id: "text-model",
      displayName: "Text Model",
      path: "/models/text-model",
      sizeBytes: 42
    )
    let decision = chatRoutingDecision(
      path: "/v1/chat/completions",
      bodyData: Data(),
      model: model,
      wantsStream: true,
      videoInspection: OpenAIVideoInspection(videos: [])
    )

    guard case .swiftLMProxy = decision else {
      fail("expected SwiftLM proxy route")
      return
    }
  }

  func testNotConfiguredVideoBackendReturnsTypedError() async throws {
    let videoFile = try writeFile(named: "clip.mkv")
    let inspection = try inspectOpenAIVideoInputs(
      in: chatRequest(videoURL: videoFile.absoluteString)
    )
    let model = ModelDescriptor(
      id: "video-model",
      displayName: "Video Model",
      path: "/models/video-model",
      sizeBytes: 42
    )
    let request = VideoChatRouteRequest(
      model: model,
      endpoint: .chatCompletions,
      bodyData: Data(),
      wantsStream: false,
      videos: inspection.videos
    )

    do {
      _ = try await NotConfiguredVideoChatBackend().complete(request)
      fail("expected not configured error")
    } catch let error as VideoChatBackendError {
      expect(error) == .notConfigured
    }
  }

  func testDispatchRulesCoverChatIngressCases() throws {
    let videoFile = try writeFile(named: "dispatch.mp4")
    let videoInspection = try inspectOpenAIVideoInputs(
      in: chatRequest(videoURL: videoFile.absoluteString)
    )
    let textInspection = OpenAIVideoInspection(videos: [])
    let cases: [(String, PreparedChatRequest, String)] = [
      (
        "text",
        preparedRequest(model: model(id: "text"), inspection: textInspection),
        "swiftLMProxy"
      ),
      (
        "text stream",
        preparedRequest(
          model: model(id: "text-stream"), wantsStream: true, inspection: textInspection),
        "swiftLMProxy"
      ),
      (
        "video stream",
        preparedRequest(
          model: model(id: "video", capabilities: .init(video: true, videoSamplingFPS: 2)),
          wantsStream: true,
          inspection: videoInspection
        ),
        "videoBackend"
      ),
      (
        "embedding",
        preparedRequest(
          model: model(id: "embedding", kind: .embedding), inspection: textInspection),
        "failure: model is an embedding model; use POST /v1/embeddings"
      ),
      (
        "missing video capability",
        preparedRequest(model: model(id: "no-video"), inspection: videoInspection),
        "failure: model does not support video input"
      ),
      (
        "wrong endpoint",
        preparedRequest(
          endpoint: .completions,
          model: model(
            id: "video-completions", capabilities: .init(video: true, videoSamplingFPS: 2)),
          inspection: videoInspection
        ),
        "failure: video input is supported only on POST /v1/chat/completions"
      ),
    ]

    for testCase in cases {
      let decision = dispatchChatRequest(testCase.1)
      expect(self.dispatchLabel(decision)) == testCase.2
    }
  }

  func testParseChatIngressReportsUnknownModelForCallerResolution() throws {
    let body = Data(
      #"{"model":"missing-model","messages":[{"role":"user","content":"hello"}]}"#.utf8
    )

    let ingress = try parseChatIngress(endpoint: .chatCompletions, bodyData: body)

    expect(ingress.modelID) == "missing-model"
    expect(ingress.wantsStream) == false
    expect(ingress.mediaInspection.containsVideo) == false
  }

  func testSSEEncoderProducesOrderedOpenAIFramesAndDone() async throws {
    let stream = AsyncThrowingStream<BackendStreamEvent, Error> { continuation in
      continuation.yield(
        .role(id: "chatcmpl-test", created: 1, model: "model-a", role: "assistant"))
      continuation.yield(
        .content(id: "chatcmpl-test", created: 1, model: "model-a", content: "hello"))
      continuation.yield(
        .finish(
          id: "chatcmpl-test",
          created: 1,
          model: "model-a",
          finishReason: "stop",
          usage: BackendUsage(promptTokens: 3, completionTokens: 2, totalTokens: 5)
        ))
      continuation.finish()
    }
    var iterator = BackendStreamingBodySequence(
      events: stream,
      appendDoneFrame: true,
      lifetimeToken: nil
    ).makeAsyncIterator()

    let role = try await stringFromNextBuffer(&iterator)
    let content = try await stringFromNextBuffer(&iterator)
    let finish = try await stringFromNextBuffer(&iterator)
    let done = try await stringFromNextBuffer(&iterator)
    let end = try await iterator.next()

    expect(role.contains(#""role":"assistant""#)) == true
    expect(content.contains(#""content":"hello""#)) == true
    expect(finish.contains(#""finish_reason":"stop""#)) == true
    expect(finish.contains(#""total_tokens":5"#)) == true
    expect(done) == "data: [DONE]\n\n"
    expect(end) == nil
  }

  func testStreamingBodyFinishesLifetimeOnceOnNormalCompletion() async throws {
    let counter = CompletionCounter()
    let token = BackendLifetimeToken {
      await counter.increment()
    }
    let stream = AsyncThrowingStream<BackendStreamEvent, Error> { continuation in
      continuation.finish()
    }
    var iterator = BackendStreamingBodySequence(
      events: stream,
      appendDoneFrame: false,
      lifetimeToken: token
    ).makeAsyncIterator()

    let next = try await iterator.next()
    expect(next) == nil
    await token.finish()

    let value = await counter.currentValue()
    expect(value) == 1
  }

  func testStreamingBodyFinishesLifetimeOnceOnThrownError() async {
    let counter = CompletionCounter()
    let token = BackendLifetimeToken {
      await counter.increment()
    }
    let stream = AsyncThrowingStream<BackendStreamEvent, Error> { continuation in
      continuation.finish(throwing: TestStreamError.failed)
    }
    var iterator = BackendStreamingBodySequence(
      events: stream,
      appendDoneFrame: false,
      lifetimeToken: token
    ).makeAsyncIterator()

    do {
      _ = try await iterator.next()
      fail("expected stream error")
    } catch TestStreamError.failed {
    } catch {
      fail("unexpected error \(error)")
    }
    await token.finish()

    let value = await counter.currentValue()
    expect(value) == 1
  }

  func testLifetimeTokenFinishesOnceForCancellationCleanup() async {
    let counter = CompletionCounter()
    let token = BackendLifetimeToken {
      await counter.increment()
    }

    await token.finish()
    await token.finish()

    let value = await counter.currentValue()
    expect(value) == 1
  }

  func testBuildsMLXVLMRequestFromOpenAIVideoMessage() throws {
    let videoFile = try writeFile(named: "clip.mp4")
    var json = chatRequest(videoURL: videoFile.absoluteString, fps: 3, maxFrames: 24)
    json["max_tokens"] = 128
    json["temperature"] = 0.2
    let bodyData = try JSONSerialization.data(withJSONObject: json)

    let request = try makeMLXVLMVideoCompletionRequest(from: bodyData)

    expect(request.messages.count) == 1
    expect(request.messages[0].role) == .user
    expect(request.messages[0].content) == "describe the clip"
    expect(request.messages[0].videoURLs) == [videoFile.standardizedFileURL]
    expect(request.fps) == 3
    expect(request.maxFrames) == 24
    expect(request.maxTokens) == 128
    expect(request.temperature) == (expected: 0.2, delta: 0.001)
  }

  func testBuildsMLXVLMRequestFromRawHTTPJSONNumbers() throws {
    let videoFile = try writeFile(named: "clip.mov")
    let json = """
      {
        "model": "model-a",
        "messages": [
          {
            "role": "user",
            "content": [
              {"type": "text", "text": "describe the clip"},
              {"type": "video_url", "video_url": {"url": "\(videoFile.absoluteString)", "fps": 1, "max_frames": 16}}
            ]
          }
        ],
        "max_tokens": 64,
        "temperature": 0
      }
      """
    let bodyData = try XCTUnwrap(json.data(using: .utf8))

    let request = try makeMLXVLMVideoCompletionRequest(from: bodyData)

    expect(request.fps) == 1
    expect(request.maxFrames) == 16
    expect(request.maxTokens) == 64
    expect(request.temperature) == 0
  }

  func testRejectsInvalidMLXVLMGenerationParametersAtRequestBoundary() throws {
    let videoFile = try writeFile(named: "clip.mp4")
    var badMaxTokens = chatRequest(videoURL: videoFile.absoluteString)
    badMaxTokens["max_tokens"] = -1
    assertVideoRequestBuildError(
      .invalidMaxTokens,
      json: badMaxTokens
    )

    var badTemperature = chatRequest(videoURL: videoFile.absoluteString)
    badTemperature["temperature"] = -0.1
    assertVideoRequestBuildError(
      .invalidTemperature,
      json: badTemperature
    )
  }

  func testEveryRouteErrorHasNonEmptyDescriptionForJSONEnvelope() {
    // The video route at lmd-serve catches typed errors and interpolates them
    // into the response envelope's `message` field. A typed error that
    // produces an empty string under `\(error)` would emit an envelope with
    // an empty `message`, which violates the "no empty reply" guarantee in
    // plan/VIDEO_ROUTING_FINAL_DECISION.md. Guard the property here so any
    // new error case must ship a non-empty description.
    let buildErrors: [VideoChatRequestBuildError] = [
      .invalidJSON,
      .missingMessages,
      .invalidMessage,
      .unsupportedRole("system"),
      .unsupportedContent,
      .noVideoContent,
      .invalidMaxTokens,
      .invalidTemperature,
    ]
    for error in buildErrors {
      let description = error.description
      expect(description.isEmpty) == false
      let interpolated = "\(error)"
      expect(interpolated.isEmpty) == false
    }

    let backendError: VideoChatBackendError = .notConfigured
    expect("\(backendError)".isEmpty) == false
  }

  // MARK: - Helpers

  private func writeFile(named name: String) throws -> URL {
    let fileURL = temporaryRoot.appendingPathComponent(name)
    try Data([0, 1, 2, 3]).write(to: fileURL)
    return fileURL.standardizedFileURL
  }

  private func model(
    id: String,
    kind: ModelKind = .chat,
    capabilities: ModelCapabilities = .textOnly
  ) -> ModelDescriptor {
    ModelDescriptor(
      id: id,
      displayName: id,
      path: "/models/\(id)",
      sizeBytes: 42,
      kind: kind,
      capabilities: capabilities
    )
  }

  private func preparedRequest(
    endpoint: OpenAIChatEndpoint = .chatCompletions,
    model: ModelDescriptor,
    wantsStream: Bool = false,
    inspection: OpenAIVideoInspection
  ) -> PreparedChatRequest {
    PreparedChatRequest(
      endpoint: endpoint,
      bodyData: Data(),
      json: [:],
      model: model,
      wantsStream: wantsStream,
      mediaInspection: inspection
    )
  }

  private func dispatchLabel(_ decision: ChatRoutingDecision) -> String {
    switch decision {
    case .swiftLMProxy:
      return "swiftLMProxy"
    case .videoBackend:
      return "videoBackend"
    case .failure(let failure):
      return "failure: \(failure.description)"
    }
  }

  private func stringFromNextBuffer(
    _ iterator: inout BackendStreamingBodySequence.Iterator
  ) async throws -> String {
    let optionalBuffer = try await iterator.next()
    let buffer = try XCTUnwrap(optionalBuffer)
    let data = Data(buffer: buffer)
    return try XCTUnwrap(String(data: data, encoding: .utf8))
  }

  private enum TestStreamError: Error {
    case failed
  }

  private func chatRequest(
    videoURL: String,
    fps: Any? = nil,
    maxFrames: Any? = nil
  ) -> [String: Any] {
    var videoURLObject: [String: Any] = ["url": videoURL]
    if let fps {
      videoURLObject["fps"] = fps
    }
    if let maxFrames {
      videoURLObject["max_frames"] = maxFrames
    }
    return [
      "model": "model-a",
      "messages": [
        [
          "role": "user",
          "content": [
            ["type": "text", "text": "describe the clip"],
            ["type": "video_url", "video_url": videoURLObject],
          ],
        ]
      ],
    ]
  }

  private func assertVideoParseError(
    _ expectedError: OpenAIVideoParseError,
    json: [String: Any],
    file: String = #filePath,
    line: UInt = #line
  ) {
    do {
      _ = try inspectOpenAIVideoInputs(in: json)
      fail("expected \(expectedError)", file: file, line: line)
    } catch let error as OpenAIVideoParseError {
      expect(file: file, line: line, error) == expectedError
    } catch {
      fail("expected \(expectedError), got \(error)", file: file, line: line)
    }
  }

  private func assertVideoRequestBuildError(
    _ expectedError: VideoChatRequestBuildError,
    json: [String: Any],
    file: String = #filePath,
    line: UInt = #line
  ) {
    do {
      let bodyData = try JSONSerialization.data(withJSONObject: json)
      _ = try makeMLXVLMVideoCompletionRequest(from: bodyData)
      fail("expected \(expectedError)", file: file, line: line)
    } catch let error as VideoChatRequestBuildError {
      expect(file: file, line: line, error) == expectedError
    } catch {
      fail("expected \(expectedError), got \(error)", file: file, line: line)
    }
  }
}
