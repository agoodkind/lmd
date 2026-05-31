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
/// The sampler uses infinite tolerance on `AVAssetImageGenerator` so a request
/// against a short clip with a single frame still produces a usable frame
/// array rather than a zero-tolerance miss.
public func sampledVideoFrames(
  originalURL: URL,
  targetFPS: Double,
  maxFrames: Int? = nil
) async throws -> [VideoFrame] {
  guard targetFPS > 0, targetFPS.isFinite else {
    throw VideoFrameSamplingError.invalidTargetFPS(targetFPS)
  }

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
  guard !videoTracks.isEmpty else {
    throw VideoFrameSamplingError.noVideoTrack(originalURL)
  }

  let durationSeconds = max(duration.seconds, 0)
  let rawCount = Int((targetFPS * durationSeconds).rounded())
  let bounded = max(rawCount, 1)
  let frameCount = min(bounded, maxFrames ?? .max)

  let generator = AVAssetImageGenerator(asset: asset)
  generator.appliesPreferredTrackTransform = true
  generator.requestedTimeToleranceBefore = .positiveInfinity
  generator.requestedTimeToleranceAfter = .positiveInfinity

  let timescale: CMTimeScale = 600
  var times: [CMTime] = []
  if frameCount == 1 || durationSeconds <= 0 {
    times.append(.zero)
  } else {
    let step = durationSeconds / Double(frameCount - 1)
    for index in 0..<frameCount {
      let seconds = Double(index) * step
      times.append(CMTime(seconds: seconds, preferredTimescale: timescale))
    }
  }

  let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
  var frames: [VideoFrame] = []
  frames.reserveCapacity(times.count)
  for (index, time) in times.enumerated() {
    do {
      let cgImage = try generator.copyCGImage(at: time, actualTime: nil)
      let ciImage = CIImage(cgImage: cgImage, options: [.colorSpace: colorSpace])
      frames.append(VideoFrame(frame: ciImage, timeStamp: time))
    } catch {
      throw VideoFrameSamplingError.frameGenerationFailed(
        at: time, total: index, reason: error.localizedDescription)
    }
  }

  guard !frames.isEmpty else {
    throw VideoFrameSamplingError.zeroFramesProduced(originalURL)
  }

  log.debug(
    "video.frame_sampling target_fps=\(targetFPS, privacy: .public) duration_s=\(durationSeconds, privacy: .public) frames=\(frames.count, privacy: .public) path=\(originalURL.path, privacy: .public)"
  )
  return frames
}
