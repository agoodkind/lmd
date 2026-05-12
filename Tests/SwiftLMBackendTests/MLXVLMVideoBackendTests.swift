//
//  MLXVLMVideoBackendTests.swift
//  SwiftLMBackendTests
//
//  Created by Alex Goodkind <alex@goodkind.io> on 2026-05-09.
//  Copyright © 2026
//

import Foundation
import MLXLMCommon
import SwiftLMCore
import XCTest
@testable import SwiftLMBackend

final class MLXVLMVideoBackendTests: XCTestCase {
  func testModelDescriptorUsesConcreteModelDescriptorPath() throws {
    let descriptor = ModelDescriptor(
      id: "local-vlm",
      displayName: "Local VLM",
      path: "/tmp/local-vlm",
      sizeBytes: 42,
      kind: .chat
    )

    let videoDescriptor = try MLXVLMVideoModelDescriptor(descriptor: descriptor)

    XCTAssertEqual(videoDescriptor.id, "local-vlm")
    XCTAssertEqual(videoDescriptor.displayName, "Local VLM")
    XCTAssertEqual(videoDescriptor.path, "/tmp/local-vlm")
    XCTAssertEqual(videoDescriptor.directoryURL.path, "/tmp/local-vlm")
    XCTAssertEqual(videoDescriptor.sizeBytes, 42)
  }

  func testRequestPreservesVideoSamplingHintsButMarksBackendAsAuthoritative() throws {
    let videoURL = try makeTemporaryVideoFile()
    let request = MLXVLMVideoCompletionRequest(
      chatText: "Describe the clip.",
      videoURLs: [videoURL],
      fps: 2,
      maxFrames: 12,
      maxTokens: 64,
      temperature: 0
    )

    XCTAssertNoThrow(try request.validate())
    let metadata = MLXVLMVideoMetadata(request: request)

    XCTAssertEqual(metadata.videoCount, 1)
    XCTAssertEqual(metadata.requestedFPS, 2)
    XCTAssertEqual(metadata.requestedMaxFrames, 12)
    XCTAssertNil(metadata.sampledFPS)
    XCTAssertNil(metadata.sampledFrameCount)
  }

  func testRequestBuildsChatMessageWithVideoURLOnLastUserMessage() throws {
    let firstVideoURL = try makeTemporaryVideoFile()
    let secondVideoURL = try makeTemporaryVideoFile()
    let request = MLXVLMVideoCompletionRequest(
      messages: [
        .user("Earlier user turn.", videoURLs: [firstVideoURL]),
        .assistant("Earlier assistant turn."),
        .user("Describe this clip."),
      ],
      videoURLs: [secondVideoURL]
    )

    try request.validate()
    let input = request.makeUserInput()

    XCTAssertEqual(input.videos.count, 2)
    guard case .chat(let chatMessages) = input.prompt else {
      return XCTFail("expected structured chat input")
    }
    XCTAssertEqual(chatMessages.count, 3)
    XCTAssertEqual(chatMessages[0].videos.count, 1)
    XCTAssertEqual(chatMessages[1].videos.count, 0)
    XCTAssertEqual(chatMessages[2].videos.count, 1)
  }

  func testRequestRejectsInvalidInputsBeforeMLXRuntime() throws {
    let videoURL = try makeTemporaryVideoFile()

    XCTAssertThrowsError(
      try MLXVLMVideoCompletionRequest(
        chatText: "Describe.",
        videoURLs: [videoURL],
        fps: 0
      ).validate()
    ) { error in
      XCTAssertEqual(error as? MLXVLMVideoBackendError, .invalidFPS(0))
    }

    XCTAssertThrowsError(
      try MLXVLMVideoCompletionRequest(
        chatText: "Describe.",
        videoURLs: [videoURL],
        maxFrames: 0
      ).validate()
    ) { error in
      XCTAssertEqual(error as? MLXVLMVideoBackendError, .invalidMaxFrames(0))
    }

    XCTAssertThrowsError(
      try MLXVLMVideoCompletionRequest(
        chatText: "Describe.",
        videoURLs: [],
        maxTokens: 0
      ).validate()
    ) { error in
      XCTAssertEqual(error as? MLXVLMVideoBackendError, .invalidMaxTokens(0))
    }

    let remoteURL = try XCTUnwrap(URL(string: "https://localhost/video.mov"))
    XCTAssertThrowsError(
      try MLXVLMVideoCompletionRequest(
        chatText: "Describe.",
        videoURLs: [remoteURL]
      ).validate()
    ) { error in
      XCTAssertEqual(error as? MLXVLMVideoBackendError, .nonFileVideoURL(remoteURL))
    }
  }

  func testResponseUsesOpenAICompatibleChatShape() throws {
    let videoURL = try makeTemporaryVideoFile()
    let request = MLXVLMVideoCompletionRequest(
      chatText: "Describe.",
      videoURLs: [videoURL],
      fps: 1,
      maxFrames: 8
    )
    let metadata = MLXVLMVideoMetadata(request: request)
    let completionInfo = MLXVLMVideoCompletionInfo(
      info: GenerateCompletionInfo(
        promptTokenCount: 11,
        generationTokenCount: 7,
        promptTime: 0.5,
        generationTime: 1.0,
        stopReason: .length
      )
    )

    let response = MLXVLMVideoChatCompletionResponse(
      id: "chatcmpl-test",
      created: 1,
      model: "local-vlm",
      content: "A short answer.",
      metadata: metadata,
      completionInfo: completionInfo
    )

    XCTAssertEqual(response.object, "chat.completion")
    XCTAssertEqual(response.choices.first?.message.role, "assistant")
    XCTAssertEqual(response.choices.first?.message.content, "A short answer.")
    XCTAssertEqual(response.choices.first?.finishReason, "length")
    XCTAssertEqual(response.usage?.promptTokens, 11)
    XCTAssertEqual(response.usage?.completionTokens, 7)
    XCTAssertEqual(response.usage?.totalTokens, 18)

    let encoded = try JSONEncoder().encode(response)
    let decoded = try JSONSerialization.jsonObject(with: encoded) as? [String: Any]
    XCTAssertNotNil(decoded?["choices"])
    XCTAssertNotNil(decoded?["usage"])
    XCTAssertNotNil(decoded?["metadata"])
    let metadataJSON = decoded?["metadata"] as? [String: Any]
    XCTAssertEqual(metadataJSON?["video_count"] as? Int, 1)
    XCTAssertEqual(metadataJSON?["requested_fps"] as? Double, 1.0)
    XCTAssertEqual(metadataJSON?["requested_max_frames"] as? Int, 8)
  }

  private func makeTemporaryVideoFile() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let fileURL = directory.appendingPathComponent("clip.mov")
    try Data([0x00, 0x00, 0x00, 0x14]).write(to: fileURL)
    addTeardownBlock {
      try? FileManager.default.removeItem(at: directory)
    }
    return fileURL
  }
}
