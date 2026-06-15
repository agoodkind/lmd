//
//  SmokeRunner.swift
//  lmd-dev
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-05-10.
//  Copyright © 2026, all rights reserved.
//

import Foundation
import SwiftMkCore

/// How long to wait for the broker `/health` endpoint, in seconds.
private let healthDeadlineSeconds: TimeInterval = 30
/// Per-request timeouts, in seconds.
private let healthRequestTimeoutSeconds: TimeInterval = 2
private let modelsRequestTimeoutSeconds: TimeInterval = 3
/// How long to wait for the broker to exit on cleanup, in seconds.
private let brokerExitTimeoutSeconds: TimeInterval = 3
/// The HTTP status code a successful smoke probe expects.
private let httpStatusOK = 200

// MARK: - SmokeRunner

final class SmokeRunner {
  private let configuration: SmokeConfiguration
  private let fileManager = FileManager.default
  private let jsonDecoder = JSONDecoder()
  private let jsonEncoder = JSONEncoder()
  private var brokerProcess: Process?
  private var temporaryDirectory: URL?

  init(configuration: SmokeConfiguration) {
    self.configuration = configuration
  }

  func run() async throws {
    temporaryDirectory = try makeTemporaryDirectory()
    defer {
      cleanup()
    }

    if configuration.useRunningDaemon {
      writeLine("using running lmd-serve at \(configuration.baseURL.absoluteString)")
    } else {
      try startBroker()
    }

    try await waitForHealth()
    writeLine("health OK")
    try await assertModels()
    try await assertLoadedModels()

    if let videoSampleFile = configuration.videoSampleFile {
      try await runVideoAcceptance(videoSampleFile: videoSampleFile)
    }

    writeLine("smoke-lmd-serve: PASS")
  }

  private func startBroker() throws {
    Output.debug("startBroker")
    guard let brokerBinary = resolveBrokerBinary() else {
      throw ToolError.failure(
        "binary missing under \(configuration.binaryDirectory.path); run 'make build' first or set LMD_BINARY_DIR"
      )
    }

    writeLine("starting lmd-serve at \(configuration.baseURL.absoluteString)")
    let process = Process()
    process.executableURL = brokerBinary
    process.arguments = []
    var environment = ProcessInfo.processInfo.environment
    environment["LMD_HOST"] = configuration.host
    environment["LMD_PORT"] = "\(configuration.port)"
    environment["LMD_DISABLE_XPC"] = "1"
    process.environment = environment
    try process.run()
    brokerProcess = process
  }

  private func resolveBrokerBinary() -> URL? {
    for candidateRelativePath in [
      "lmd-serve", "lmd_serve", "Release/lmd-serve", "Release/lmd_serve",
    ] {
      let candidate = configuration.binaryDirectory.appendingPathComponent(candidateRelativePath)
      if fileManager.isExecutableFile(atPath: candidate.path) {
        return candidate
      }
    }
    return nil
  }

  private func waitForHealth() async throws {
    let deadline = Date().addingTimeInterval(healthDeadlineSeconds)
    var lastError: Error?
    while Date() < deadline {
      try assertBrokerStillRunning()
      do {
        let response = try await request(path: "health", timeout: healthRequestTimeoutSeconds)
        if response.statusCode == httpStatusOK {
          return
        }
      } catch {
        Output.notice("health probe failed, will retry error=\(error)")
        lastError = error
      }
      try assertBrokerStillRunning()
      await pollDelayAsync(seconds: healthPollSeconds)
    }

    if let lastError {
      throw ToolError.failure("daemon failed to come up: \(lastError)")
    }
    throw ToolError.failure("daemon failed to come up")
  }

  private func assertBrokerStillRunning() throws {
    guard let brokerProcess else {
      return
    }
    guard !brokerProcess.isRunning else {
      return
    }
    throw ToolError.failure(
      "daemon exited before /health became ready with status \(brokerProcess.terminationStatus)")
  }

  private func assertModels() async throws {
    let response = try await request(path: "v1/models", timeout: modelsRequestTimeoutSeconds)
    guard response.statusCode == httpStatusOK else {
      throw ToolError.failure(
        "GET /v1/models failed with HTTP \(response.statusCode); response body: \(bodySnippet(response.data))"
      )
    }
    let models = try jsonDecoder.decode(ModelsResponse.self, from: response.data)
    guard models.object == "list" else {
      throw ToolError.failure("bad /v1/models object field: \(models.object)")
    }
    writeLine("models: \(models.data.count)")
  }

  private func assertLoadedModels() async throws {
    let response = try await request(path: "swiftlmd/loaded", timeout: modelsRequestTimeoutSeconds)
    guard response.statusCode == httpStatusOK else {
      throw ToolError.failure(
        "GET /swiftlmd/loaded failed with HTTP \(response.statusCode); response body: \(bodySnippet(response.data))"
      )
    }
    let loaded = try jsonDecoder.decode(LoadedModelsResponse.self, from: response.data)
    if configuration.useRunningDaemon {
      writeLine(
        "loaded-models observed: count=\(loaded.models.count) allocated_gb=\(loaded.allocatedGB)")
      return
    }
    guard loaded.models.isEmpty else {
      throw ToolError.failure("expected empty loaded models, got \(loaded.models.count)")
    }
    guard loaded.allocatedGB == 0 else {
      throw ToolError.failure("expected 0 GB, got \(loaded.allocatedGB)")
    }
    writeLine("loaded-models empty OK")
  }

  private func runVideoAcceptance(videoSampleFile: URL) async throws {
    let sampleCopy = try copyVideoSampleToTemporaryDirectory(videoSampleFile)
    let requestBody = try buildVideoRequest(videoFile: sampleCopy)
    writeLine(
      "video acceptance: POST /v1/chat/completions model=\(configuration.videoModel) sample=\(sampleCopy.lastPathComponent)"
    )

    let response = try await request(
      path: "v1/chat/completions",
      timeout: configuration.videoTimeoutSeconds,
      method: "POST",
      body: requestBody
    )
    let responseText = bodySnippet(response.data)

    // The spec at plan/VIDEO_ROUTING_FINAL_DECISION.md requires HTTP 200 with a
    // populated assistant message because frame sampling at infinite tolerance
    // succeeds against both the 1-frame and 2-second fixtures.
    guard response.statusCode == httpStatusOK else {
      throw ToolError.failure(
        "video acceptance failed with HTTP \(response.statusCode); response body: \(responseText)")
    }
    let completion = try jsonDecoder.decode(ChatCompletionResponse.self, from: response.data)
    guard let firstChoice = completion.choices.first else {
      throw ToolError.failure(
        "video acceptance returned HTTP 200 but choices was empty; response body: \(responseText)")
    }
    guard firstChoice.message.content.isNonEmpty else {
      throw ToolError.failure(
        "video acceptance returned HTTP 200 but choices.0.message.content was empty; response body: \(responseText)"
      )
    }
    writeLine("video acceptance OK: non-empty VLM response from \(configuration.videoModel)")
  }

  private func copyVideoSampleToTemporaryDirectory(_ videoSampleFile: URL) throws -> URL {
    Output.debug("copyVideoSampleToTemporaryDirectory sample=\(videoSampleFile.lastPathComponent)")
    guard fileManager.fileExists(atPath: videoSampleFile.path) else {
      throw ToolError.failure("video sample missing at \(videoSampleFile.path)")
    }
    guard fileManager.isReadableFile(atPath: videoSampleFile.path) else {
      throw ToolError.failure("video sample is not readable at \(videoSampleFile.path)")
    }
    let resourceValues = try videoSampleFile.resourceValues(forKeys: [.isRegularFileKey])
    guard resourceValues.isRegularFile == true else {
      throw ToolError.failure(
        "video sample must point to a regular file at \(videoSampleFile.path)")
    }
    let videoExtension = videoSampleFile.pathExtension.lowercased()
    guard supportedVideoExtensions.contains(videoExtension) else {
      throw ToolError.failure("video sample must use a route-supported video extension")
    }
    guard let temporaryDirectory else {
      throw ToolError.failure("temporary directory was not initialized")
    }

    let destination = temporaryDirectory.appendingPathComponent(
      "lmd-video-sample.\(videoExtension)")
    try fileManager.copyItem(at: videoSampleFile, to: destination)
    return destination.standardizedFileURL
  }

  private func buildVideoRequest(videoFile: URL) throws -> Data {
    let request = VideoChatRequest(
      model: configuration.videoModel,
      messages: [
        VideoChatRequest.Message(
          role: "user",
          content: [
            .text("Describe the visible motion in this video in one concise sentence."),
            .video(url: videoFile),
          ]
        )
      ],
      maxTokens: configuration.videoMaxTokens,
      temperature: 0
    )
    return try jsonEncoder.encode(request)
  }

  private func request(
    path: String,
    timeout: TimeInterval,
    method: String = "GET",
    body: Data? = nil
  ) async throws -> HTTPResult {
    Output.debug("request path=\(path) method=\(method)")
    let url = configuration.baseURL.appendingPathComponent(path)
    var request = URLRequest(url: url, timeoutInterval: timeout)
    request.httpMethod = method
    request.httpBody = body
    if body != nil {
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    }
    let (data, response) = try await URLSession.shared.data(for: request)
    let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
    return HTTPResult(statusCode: statusCode, data: data)
  }

  private func makeTemporaryDirectory() throws -> URL {
    Output.debug("makeTemporaryDirectory")
    let temporaryURL = fileManager.temporaryDirectory
      .appendingPathComponent("lmd-smoke-\(UUID().uuidString)", isDirectory: true)
    try fileManager.createDirectory(at: temporaryURL, withIntermediateDirectories: true)
    return temporaryURL
  }

  private func cleanup() {
    Output.debug("cleanup")
    if let brokerProcess {
      brokerProcess.terminate()
      if !waitForProcessExit(brokerProcess, timeout: brokerExitTimeoutSeconds) {
        kill(brokerProcess.processIdentifier, SIGKILL)
      }
    }
    guard let temporaryDirectory else {
      return
    }
    do {
      try fileManager.removeItem(at: temporaryDirectory)
    } catch {
      Output.warning("smoke cleanup failed path=\(temporaryDirectory.path) error=\(error)")
    }
  }
}
