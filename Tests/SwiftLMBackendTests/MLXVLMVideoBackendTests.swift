//
//  MLXVLMVideoBackendTests.swift
//  SwiftLMBackendTests
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-05-09.
//  Copyright © 2026, all rights reserved.
//

import Foundation
import MLXLMCommon
import Nimble
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

    expect(videoDescriptor.id) == "local-vlm"
    expect(videoDescriptor.displayName) == "Local VLM"
    expect(videoDescriptor.path) == "/tmp/local-vlm"
    expect(videoDescriptor.directoryURL.path) == "/tmp/local-vlm"
    expect(videoDescriptor.sizeBytes) == 42
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

    expect { try request.validate() }.toNot(throwError())
    let metadata = MLXVLMVideoMetadata(request: request)

    expect(metadata.videoCount) == 1
    expect(metadata.requestedFPS) == 2
    expect(metadata.requestedMaxFrames) == 12
    expect(metadata.sampledFPS) == nil
    expect(metadata.sampledFrameCount) == nil
  }

  func testReplacingVideosPreservesRequestedAndSampledMetadata() throws {
    let videoURL = try makeTemporaryVideoFile()
    let request = MLXVLMVideoCompletionRequest(
      chatText: "Describe the clip.",
      videoURLs: [videoURL],
      fps: 16,
      maxFrames: 48,
      maxTokens: 64,
      temperature: 0
    )
    let replaced = request.replacingVideos(
      [.frames([])],
      sampledFrameCount: 32,
      sampledFPS: 16
    )
    let metadata = MLXVLMVideoMetadata(request: replaced)

    expect(metadata.videoCount) == 1
    expect(metadata.requestedFPS) == 16
    expect(metadata.requestedMaxFrames) == 48
    expect(metadata.sampledFPS) == 16
    expect(metadata.sampledFrameCount) == 32
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

    expect(input.videos.count) == 2
    guard case .chat(let chatMessages) = input.prompt else {
      fail("expected structured chat input")
      return
    }
    expect(chatMessages.count) == 3
    expect(chatMessages[0].videos.count) == 1
    expect(chatMessages[1].videos.count) == 0
    expect(chatMessages[2].videos.count) == 1
  }

  func testRequestRejectsInvalidInputsBeforeMLXRuntime() throws {
    let videoURL = try makeTemporaryVideoFile()

    expect {
      try MLXVLMVideoCompletionRequest(
        chatText: "Describe.",
        videoURLs: [videoURL],
        fps: 0
      ).validate()
    }.to(throwError(MLXVLMVideoBackendError.invalidFPS(0)))

    expect {
      try MLXVLMVideoCompletionRequest(
        chatText: "Describe.",
        videoURLs: [videoURL],
        maxFrames: 0
      ).validate()
    }.to(throwError(MLXVLMVideoBackendError.invalidMaxFrames(0)))

    expect {
      try MLXVLMVideoCompletionRequest(
        chatText: "Describe.",
        videoURLs: [],
        maxTokens: 0
      ).validate()
    }.to(throwError(MLXVLMVideoBackendError.invalidMaxTokens(0)))

    let remoteURL = try XCTUnwrap(URL(string: "https://localhost/video.mov"))
    expect {
      try MLXVLMVideoCompletionRequest(
        chatText: "Describe.",
        videoURLs: [remoteURL]
      ).validate()
    }.to(throwError(MLXVLMVideoBackendError.nonFileVideoURL(remoteURL)))
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
      model: "local-vlm",
      content: "A short answer.",
      metadata: metadata,
      completionInfo: completionInfo,
      id: "chatcmpl-test",
      created: 1
    )

    expect(response.object) == "chat.completion"
    expect(response.choices.first?.message.role) == "assistant"
    expect(response.choices.first?.message.content) == "A short answer."
    expect(response.choices.first?.finishReason) == "length"
    expect(response.usage?.promptTokens) == 11
    expect(response.usage?.completionTokens) == 7
    expect(response.usage?.totalTokens) == 18

    let encoded = try JSONEncoder().encode(response)
    let decoded = try JSONSerialization.jsonObject(with: encoded) as? [String: Any]
    expect(decoded?["choices"]) != nil
    expect(decoded?["usage"]) != nil
    expect(decoded?["metadata"]) != nil
    let metadataJSON = decoded?["metadata"] as? [String: Any]
    expect(metadataJSON?["video_count"] as? Int) == 1
    expect(metadataJSON?["requested_fps"] as? Double) == 1.0
    expect(metadataJSON?["requested_max_frames"] as? Int) == 8
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
