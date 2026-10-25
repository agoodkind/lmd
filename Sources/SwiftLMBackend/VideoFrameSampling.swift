//
//  VideoFrameSampling.swift
//  SwiftLMBackend
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-05-10.
//  Copyright © 2026, all rights reserved.
//

import AVFoundation
import AppLogger
import CoreImage
import Foundation
import MLXLMCommon
import MLXVLM

private let log = AppLogger.logger(category: "VideoFrameSampling")
private let signposter = AppLogger.signposter(category: "Performance")

public enum VideoFrameSamplingError: Error, Equatable, CustomStringConvertible {
  case noVideoTrack(URL)
  case assetLoadFailed(URL, reason: String)
  case frameGenerationFailed(at: CMTime, total: Int, reason: String)
  case invalidTargetFPS(Double)
  case zeroFramesProduced(URL)

  public var description: String {
    switch self {
    case .noVideoTrack(let url):
      return "video file has no decodable video track: \(url.path)"
    case .assetLoadFailed(let url, let reason):
      return "failed to load video asset \(url.path): \(reason)"
    case .frameGenerationFailed(let time, let total, let reason):
      return "failed to extract frame at \(time.seconds)s of \(total): \(reason)"
    case .invalidTargetFPS(let fps):
      return "targetFPS must be > 0, got \(fps)"
    case .zeroFramesProduced(let url):
      return "frame sampler produced zero frames for \(url.path)"
    }
  }
}

/// Extract a sampled array of `VideoFrame` from a local video file.
///
/// Decode source frames once and preserve their presentation timestamps.
public func sampledVideoFrames(
  originalURL: URL,
  targetFPS: Double,
  maxFrames: Int? = nil
) async throws -> [VideoFrame] {
  guard targetFPS > 0, targetFPS.isFinite else {
    throw VideoFrameSamplingError.invalidTargetFPS(targetFPS)
  }
  let interval = signposter.beginInterval(
    "video.frame_sampling", id: signposter.makeSignpostID())
  defer { signposter.endInterval("video.frame_sampling", interval) }

  let asset = AVURLAsset(url: originalURL)
  let duration: CMTime
  do {
    duration = try await asset.load(.duration)
  } catch {
    throw VideoFrameSamplingError.assetLoadFailed(
      originalURL, reason: error.localizedDescription)
  }

  let videoTracks: [AVAssetTrack]
  do {
    videoTracks = try await asset.loadTracks(withMediaType: .video)
  } catch {
    throw VideoFrameSamplingError.assetLoadFailed(
      originalURL, reason: error.localizedDescription)
  }
  guard let track = videoTracks.first else {
    throw VideoFrameSamplingError.noVideoTrack(originalURL)
  }

  let durationSeconds = max(duration.seconds, 0)
  guard durationSeconds.isFinite else {
    throw VideoFrameSamplingError.assetLoadFailed(
      originalURL, reason: "Video duration must be finite.")
  }
  let transform: CGAffineTransform
  do {
    transform = try await track.load(.preferredTransform)
  } catch {
    throw VideoFrameSamplingError.assetLoadFailed(
      originalURL, reason: error.localizedDescription)
  }

  let parameters = VideoFrameSamplingParameters(
    originalURL: originalURL,
    targetFPS: targetFPS,
    maxFrames: maxFrames,
    durationSeconds: durationSeconds)
  let frames = try decodeVideoFrames(
    asset: asset, track: track, transform: transform, parameters: parameters)
  log.debug(
    "video.frame_sampling target_fps=\(targetFPS, privacy: .public) duration_s=\(durationSeconds, privacy: .public) frames=\(frames.count, privacy: .public) path=\(originalURL.path, privacy: .public)"
  )
  return frames
}

// MARK: - VideoFrameSamplingParameters

private struct VideoFrameSamplingParameters {
  let originalURL: URL
  let targetFPS: Double
  let maxFrames: Int?
  let durationSeconds: Double
}

private func decodeVideoFrames(
  asset: AVURLAsset,
  track: AVAssetTrack,
  transform: CGAffineTransform,
  parameters: VideoFrameSamplingParameters
) throws -> [VideoFrame] {
  var selection = try VideoFrameSelection(parameters: parameters)
  let reader: AVAssetReader
  do {
    reader = try AVAssetReader(asset: asset)
  } catch {
    throw VideoFrameSamplingError.assetLoadFailed(
      parameters.originalURL, reason: error.localizedDescription)
  }
  let output = AVAssetReaderTrackOutput(
    track: track,
    outputSettings: [
      kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
    ])
  output.alwaysCopiesSampleData = false
  guard reader.canAdd(output) else {
    throw VideoFrameSamplingError.assetLoadFailed(
      parameters.originalURL, reason: "Video decoder cannot read this track.")
  }
  reader.add(output)
  guard reader.startReading() else {
    throw VideoFrameSamplingError.assetLoadFailed(
      parameters.originalURL,
      reason: reader.error?.localizedDescription ?? "Video decoding did not start.")
  }
  defer { reader.cancelReading() }

  while let sample = output.copyNextSampleBuffer() {
    try selection.append(sample, transform: transform)
    if selection.reachedLimit { break }
  }
  return try selection.finish(reader: reader, transform: transform)
}

// MARK: - VideoFrameSelection

private struct VideoFrameSelection {
  private let parameters: VideoFrameSamplingParameters
  private let frameLimit: Int
  private let coversClip: Bool
  private let sampleInterval: Double
  private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
  private var frames: [VideoFrame] = []
  private var nextSampleTime = 0.0
  private var lastSourceSample: CMSampleBuffer?
  private var lastSourceTime = CMTime.zero

  init(parameters: VideoFrameSamplingParameters) throws {
    self.parameters = parameters
    frameLimit = parameters.maxFrames ?? .max
    guard frameLimit > 0 else {
      throw VideoFrameSamplingError.zeroFramesProduced(parameters.originalURL)
    }
    coversClip =
      parameters.maxFrames != nil && frameLimit > 1
      && parameters.durationSeconds * parameters.targetFPS > Double(frameLimit)
    if coversClip {
      sampleInterval = parameters.durationSeconds / Double(frameLimit - 1)
    } else {
      sampleInterval = 1 / parameters.targetFPS
    }
  }

  var reachedLimit: Bool { frames.count == frameLimit }

  mutating func append(_ sample: CMSampleBuffer, transform: CGAffineTransform) throws {
    let time = CMSampleBufferGetPresentationTimeStamp(sample)
    lastSourceTime = time
    guard time.isNumeric, time.seconds >= 0 else {
      throw VideoFrameSamplingError.frameGenerationFailed(
        at: time,
        total: frames.count,
        reason: "Decoded frame has an invalid presentation timestamp.")
    }
    if coversClip {
      lastSourceSample = sample
    }
    guard time.seconds >= nextSampleTime else { return }
    frames.append(try frame(from: sample, transform: transform))
    nextSampleTime = (floor(time.seconds / sampleInterval) + 1) * sampleInterval
  }

  mutating func finish(reader: AVAssetReader, transform: CGAffineTransform) throws -> [VideoFrame] {
    guard reachedLimit || reader.status == .completed else {
      throw VideoFrameSamplingError.frameGenerationFailed(
        at: lastSourceTime,
        total: frames.count,
        reason: reader.error?.localizedDescription ?? "Video decoding did not complete.")
    }
    if coversClip, frames.count < frameLimit, let sample = lastSourceSample,
      let previous = frames.last, CMTimeCompare(lastSourceTime, previous.timeStamp) > 0
    {
      frames.append(try frame(from: sample, transform: transform))
    }
    guard !frames.isEmpty else {
      throw VideoFrameSamplingError.zeroFramesProduced(parameters.originalURL)
    }
    return frames
  }

  private func frame(from sample: CMSampleBuffer, transform: CGAffineTransform) throws -> VideoFrame
  {
    let time = CMSampleBufferGetPresentationTimeStamp(sample)
    guard let buffer = CMSampleBufferGetImageBuffer(sample) else {
      throw VideoFrameSamplingError.frameGenerationFailed(
        at: time,
        total: frames.count,
        reason: "Video decoder did not produce an image.")
    }
    let image = CIImage(cvPixelBuffer: buffer, options: [.colorSpace: colorSpace])
      .transformed(by: transform)
    return VideoFrame(frame: image, timeStamp: time)
  }
}
