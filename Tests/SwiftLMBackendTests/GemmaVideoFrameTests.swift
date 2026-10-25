//
//  GemmaVideoFrameTests.swift
//  SwiftLMBackendTests
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-10-24.
//  Copyright © 2026, all rights reserved.
//

import AVFoundation
import AppLogger
import CoreImage
import Foundation
import MLX
import MLXHuggingFace
import MLXLMCommon
import MLXVLM
import Nimble
import Tokenizers
import XCTest

@testable import SwiftLMBackend

private let log = AppLogger.logger(category: "GemmaVideoFrameTests")

final class GemmaVideoFrameTests: XCTestCase {
  private var previousMemoryLimit = 0
  private var previousCacheLimit = 0

  override func setUp() {
    super.setUp()
    previousMemoryLimit = Memory.memoryLimit
    previousCacheLimit = Memory.cacheLimit
    Memory.memoryLimit = 64 * 1_024 * 1_024
    Memory.cacheLimit = 0
  }

  override func tearDown() {
    Memory.clearCache()
    Memory.memoryLimit = previousMemoryLimit
    Memory.cacheLimit = previousCacheLimit
    super.tearDown()
  }

  func testRequestPreservesFortyFramesAndFractionalTimestampsThroughGemmaProcessor() async throws {
    let frameCount = 40
    let frames = (0..<frameCount).map { index in
      VideoFrame(
        frame: CIImage(color: CIColor(red: 1, green: 0, blue: 0))
          .cropped(to: CGRect(x: 0, y: 0, width: 4, height: 4)),
        timeStamp: CMTime(value: Int64(index), timescale: 16)
      )
    }
    let request = MLXVLMVideoCompletionRequest(
      messages: [.user("Describe the clip.")],
      preSampledVideos: [.frames(frames)],
      sampledFrameCount: frameCount,
      sampledFPS: 16,
      fps: 16
    )
    let userInput = request.makeUserInput()
    let video = try XCTUnwrap(userInput.videos.first)
    guard case .frames(let preservedFrames) = video else {
      XCTFail("The request must preserve decoded video frames.")
      return
    }
    expect(preservedFrames.count) == frameCount
    for (index, frame) in preservedFrames.enumerated() {
      expect(frame.timeStamp.seconds).to(beCloseTo(Double(index) / 16, within: 0.000001))
    }

    let (processor, tokenizer) = try await makeProcessor()
    let prepared = try await processor.prepare(input: userInput)
    try assertVideoPixels(prepared, frameCount: frameCount)
    let tokenIDs = prepared.text.tokens.asArray(Int.self)
    expect(tokenIDs.filter { $0 == 1 }.count) == frameCount * 4

    var expectedBlocks: [String] = []
    for index in 0..<frameCount {
      let microseconds = index * 62_500
      let seconds = microseconds / 1_000_000
      let fraction = microseconds % 1_000_000
      let timestamp = String(format: "00:%02d.%06d", seconds, fraction)
      expectedBlocks.append(
        timestamp + " <start_of_image>"
          + String(repeating: "<|video|>", count: 4) + "<end_of_image>"
      )
    }
    let decoded = tokenizer.decode(tokenIds: tokenIDs, skipSpecialTokens: false)
    expect(decoded) == expectedBlocks.joined(separator: " ") + "Describe the clip."
    expect(decoded.contains("00:00.062500 <start_of_image>")) == true
    expect(decoded.contains("00:02.437500 <start_of_image>")) == true
  }

  func testSamplerHonorsExplicitCapBeforeGemmaPreparation() async throws {
    let clipURL = try await makeVideoClip()
    let sourceFrames = try await decodedClipFrames(at: clipURL)
    expect(sourceFrames.map(\.index)) == Array(0..<48)
    for (index, frame) in sourceFrames.enumerated() {
      expect(frame.timeStamp.seconds).to(beCloseTo(Double(index) / 16, within: 0.000001))
    }
    let uncappedFrames = try await sampledVideoFrames(originalURL: clipURL, targetFPS: 16)
    expect(uncappedFrames.count) == 48
    let decodedIndices = try uncappedFrames.map { try decodedFrameIndex($0.frame) }
    expect(decodedIndices) == Array(0..<48)
    for (index, frame) in uncappedFrames.enumerated() {
      expect(frame.timeStamp.seconds).to(beCloseTo(Double(index) / 16, within: 0.000001))
    }

    let cappedFrames = try await sampledVideoFrames(
      originalURL: clipURL, targetFPS: 16, maxFrames: 3)
    expect(cappedFrames.count) == 3
    let cappedIndices = try cappedFrames.map { try decodedFrameIndex($0.frame) }
    expect(cappedIndices) == [0, 24, 47]
    for (frame, index) in zip(cappedFrames, cappedIndices) {
      expect(frame.timeStamp.seconds).to(beCloseTo(Double(index) / 16, within: 0.000001))
      expect(frame.timeStamp.seconds) < 3
    }

    let request = MLXVLMVideoCompletionRequest(
      chatText: "Describe the clip.", videoURLs: [clipURL], fps: 16, maxFrames: 3
    ).replacingVideos([.frames(cappedFrames)], sampledFrameCount: 3, sampledFPS: 16)
    let (processor, tokenizer) = try await makeProcessor()
    let prepared = try await processor.prepare(input: request.makeUserInput())
    try assertVideoPixels(prepared, frameCount: 3)
    let tokenIDs = prepared.text.tokens.asArray(Int.self)
    expect(tokenIDs.filter { $0 == 1 }.count) == 12
    let decoded = tokenizer.decode(tokenIds: tokenIDs, skipSpecialTokens: false)
    expect(decoded.contains("00:01.500000 <start_of_image>")) == true
    expect(decoded.contains("00:02.937500 <start_of_image>")) == true
  }

  func testSamplerDoesNotDuplicateFramesBelowRequestedRate() async throws {
    let clipURL = try await makeVideoClip(frameCount: 6, frameRate: 2)
    let frames = try await sampledVideoFrames(originalURL: clipURL, targetFPS: 16)
    expect(frames.count) == 6
    expect(try frames.map { try decodedFrameIndex($0.frame) }) == Array(0..<6)
    for (index, frame) in frames.enumerated() {
      expect(frame.timeStamp.seconds).to(beCloseTo(Double(index) / 2, within: 0.000001))
    }
  }

  func testSamplerSkipsSourceFramesAtLowerRequestedRate() async throws {
    let clipURL = try await makeVideoClip()
    let frames = try await sampledVideoFrames(originalURL: clipURL, targetFPS: 2)
    expect(try frames.map { try decodedFrameIndex($0.frame) }) == [0, 8, 16, 24, 32, 40]
    for (index, frame) in frames.enumerated() {
      expect(frame.timeStamp.seconds).to(beCloseTo(Double(index) / 2, within: 0.000001))
    }
  }

  func testSamplerPreservesOneFrameAndShortClips() async throws {
    for frameCount in [1, 2] {
      let clipURL = try await makeVideoClip(frameCount: frameCount)
      let frames = try await sampledVideoFrames(originalURL: clipURL, targetFPS: 16)
      expect(frames.count) == frameCount
      expect(try frames.map { try decodedFrameIndex($0.frame) }) == Array(0..<frameCount)
      for (index, frame) in frames.enumerated() {
        expect(frame.timeStamp.seconds).to(beCloseTo(Double(index) / 16, within: 0.000001))
      }
    }
  }

  func testSamplerPreservesTrackOrientation() async throws {
    let rotation = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 48, ty: 0)
    let clipURL = try await makeVideoClip(
      frameCount: 1, width: 32, height: 48, firstFrameIndex: 37, transform: rotation)
    let asset = AVURLAsset(url: clipURL)
    let tracks = try await asset.loadTracks(withMediaType: .video)
    let track = try XCTUnwrap(tracks.first)
    let sourceSize = try await track.load(.naturalSize)
    let preferredTransform = try await track.load(.preferredTransform)
    let sourceFrames = try await decodedClipFrames(at: clipURL)
    expect(sourceSize) == CGSize(width: 32, height: 48)
    expect(preferredTransform) == rotation
    expect(sourceFrames.map(\.index)) == [37]

    let frames = try await sampledVideoFrames(originalURL: clipURL, targetFPS: 16)
    expect(frames.count) == 1
    let frame = try XCTUnwrap(frames.first)
    expect(frame.frame.extent) == CGRect(x: 0, y: 0, width: 48, height: 32)
    expect(try self.decodedFrameIndex(frame.frame, transformedBy: preferredTransform)) == 37
    expect(frame.timeStamp.seconds) == 0
  }

  func testEncodedFixtureContainsFortyEightDistinctFrames() async throws {
    let clipURL = try await makeVideoClip()
    let frames = try await decodedClipFrames(at: clipURL)
    expect(frames.map(\.index)) == Array(0..<48)
    for (index, frame) in frames.enumerated() {
      expect(frame.timeStamp.seconds).to(beCloseTo(Double(index) / 16, within: 0.000001))
    }
  }

}

// MARK: - GemmaVideoFrameTests

extension GemmaVideoFrameTests {
  private func makeProcessor() async throws -> (Gemma4Processor, any MLXLMCommon.Tokenizer) {
    #if SWIFT_PACKAGE
      let bundle = Bundle.module
    #else
      let bundle = Bundle(for: GemmaVideoFrameTests.self)
    #endif
    let directory = try XCTUnwrap(
      bundle.url(forResource: "GemmaVideoTokenizer", withExtension: nil))
    let upstream = try await AutoTokenizer.from(modelFolder: directory)
    let tokenizer = #adaptHuggingFaceTokenizer(upstream)
    let configData = try Data(
      contentsOf: directory.appendingPathComponent("preprocessor_config.json"))
    let configuration = try JSONDecoder().decode(
      Gemma4ProcessorConfiguration.self, from: configData)
    return (Gemma4Processor(configuration, tokenizer: tokenizer), tokenizer)
  }

  private func decodedClipFrames(at url: URL) async throws -> [(index: Int, timeStamp: CMTime)] {
    let asset = AVURLAsset(url: url)
    let tracks = try await asset.loadTracks(withMediaType: .video)
    let track = try XCTUnwrap(tracks.first)
    let reader = try AVAssetReader(asset: asset)
    let output = AVAssetReaderTrackOutput(
      track: track,
      outputSettings: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
      ])
    output.alwaysCopiesSampleData = false
    reader.add(output)
    guard reader.startReading() else {
      throw FixtureError.readerFailed(
        reader.error?.localizedDescription ?? "Video decoding did not start.")
    }
    var frames: [(index: Int, timeStamp: CMTime)] = []
    while let sample = output.copyNextSampleBuffer() {
      let buffer = try XCTUnwrap(CMSampleBufferGetImageBuffer(sample))
      frames.append(
        (
          index: try decodedFrameIndex(CIImage(cvPixelBuffer: buffer)),
          timeStamp: CMSampleBufferGetPresentationTimeStamp(sample)
        ))
    }
    guard reader.status == .completed else {
      throw FixtureError.readerFailed(
        reader.error?.localizedDescription ?? "Video decoding did not complete.")
    }
    return frames
  }

  private func assertVideoPixels(_ input: LMInput, frameCount: Int) throws {
    let video = try XCTUnwrap(input.video)
    let frameSizes = try XCTUnwrap(video.frames)
    expect(video.pixels.shape) == [frameCount, 3, 4, 4]
    expect(frameSizes.count) == frameCount
    for frame in frameSizes {
      expect(frame.t) == 1
      expect(frame.h) == 4
      expect(frame.w) == 4
    }
    let pixels = video.pixels.asArray(Float.self)
    expect(pixels.count) == frameCount * 4 * 4 * 3
    expect(try XCTUnwrap(pixels.max())) > 0
    expect(input.image) == nil
  }

  private func makeVideoClip(
    frameCount: Int = 48,
    frameRate: CMTimeScale = 16,
    width: Int = 32,
    height: Int = 32,
    firstFrameIndex: Int = 0,
    transform: CGAffineTransform = .identity
  ) async throws -> URL {
    let clipURL = try makeVideoClipURL()
    let writer = try AVAssetWriter(outputURL: clipURL, fileType: .mov)
    let input = AVAssetWriterInput(
      mediaType: .video,
      outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.h264,
        AVVideoWidthKey: width,
        AVVideoHeightKey: height,
      ]
    )
    input.mediaTimeScale = frameRate
    input.transform = transform
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(
      assetWriterInput: input,
      sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferWidthKey as String: width,
        kCVPixelBufferHeightKey as String: height,
      ]
    )
    writer.add(input)
    expect(writer.startWriting()) == true
    writer.startSession(atSourceTime: .zero)
    let pool = try XCTUnwrap(adaptor.pixelBufferPool)
    let context = CIContext()
    let deadline = Date().addingTimeInterval(10)
    for index in 0..<frameCount {
      while !input.isReadyForMoreMediaData {
        guard writer.status == .writing, Date() < deadline else {
          throw FixtureError.writerFailed(
            writer.error?.localizedDescription ?? "Video encoding timed out.")
        }
        try await Task.sleep(for: .milliseconds(1))
      }
      var buffer: CVPixelBuffer?
      expect(CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)) == kCVReturnSuccess
      let pixelBuffer = try XCTUnwrap(buffer)
      context.render(
        frameImage(index: firstFrameIndex + index, width: width, height: height), to: pixelBuffer)
      guard
        adaptor.append(
          pixelBuffer, withPresentationTime: CMTime(value: Int64(index), timescale: frameRate))
      else {
        throw FixtureError.writerFailed(
          writer.error?.localizedDescription ?? "Video encoding rejected a frame.")
      }
    }
    writer.endSession(atSourceTime: CMTime(value: Int64(frameCount), timescale: frameRate))
    input.markAsFinished()
    await writer.finishWriting()
    guard writer.status == .completed else {
      throw FixtureError.writerFailed(
        writer.error?.localizedDescription ?? "Video encoding did not complete.")
    }
    log.debug("video.fixture_created path=\(clipURL.path, privacy: .public)")
    return clipURL
  }

  private func makeVideoClipURL() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    addTeardownBlock {
      try FileManager.default.removeItem(at: directory)
    }
    return directory.appendingPathComponent("clip.mov")
  }

  private func frameImage(index: Int, width: Int, height: Int) -> CIImage {
    var image = CIImage(color: .black)
      .cropped(to: CGRect(x: 0, y: 0, width: width, height: height))
    for (bit, value) in [1, 2, 4, 8, 16, 32].enumerated() {
      let color: CIColor
      if index & value != 0 {
        color = .white
      } else {
        color = .black
      }
      let stripe = CIImage(color: color)
        .cropped(to: CGRect(x: bit * 5, y: 0, width: 5, height: height))
      image = stripe.composited(over: image)
    }
    return image
  }

  private func decodedFrameIndex(
    _ image: CIImage, transformedBy transform: CGAffineTransform = .identity
  ) throws -> Int {
    let colorSpace = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
    let context = CIContext()
    var index = 0
    for (bit, value) in [1, 2, 4, 8, 16, 32].enumerated() {
      let point = CGPoint(x: bit * 5 + 2, y: 16).applying(transform)
      var pixel: [UInt8] = [0, 0, 0, 0]
      context.render(
        image,
        toBitmap: &pixel,
        rowBytes: 4,
        bounds: CGRect(x: point.x, y: point.y, width: 1, height: 1),
        format: .RGBA8,
        colorSpace: colorSpace)
      if pixel[0] > 127 {
        index += value
      }
    }
    return index
  }

  private enum FixtureError: Error {
    case writerFailed(String)
    case readerFailed(String)
  }
}
