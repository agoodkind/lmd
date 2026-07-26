//
//  DevTool+MXFP8.swift
//  lmd-dev
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-07-25.
//  Copyright © 2026, all rights reserved.
//

import Foundation
import SwiftLMEmbed
import SwiftMkCore

private let mxFP8GroupSize = 32
private let mxFP8Bits = 8
private let mxFP8Mode = "mxfp8"
private let mxFP8DestinationSuffix = "-mxfp8"
private let consolidatedWeightsName = "model.safetensors"

/// The shard map belonging to the source checkpoint. Conversion writes one
/// consolidated weights file, so copying this map would leave the destination
/// pointing at shard files that do not exist there.
private let shardIndexName = "model.safetensors.index.json"

// MARK: - JSONValue

/// A concrete representation of arbitrary JSON.
///
/// Conversion has to preserve every key of the source `config.json` while
/// adding one of its own, and the model config carries fields this tool does
/// not model. This type round-trips those fields without an untyped dictionary.
enum JSONValue: Codable, Equatable, Sendable {
  case array([JSONValue])
  case bool(Bool)
  case null
  case number(Double)
  case object([String: JSONValue])
  case string(String)

  init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    if container.decodeNil() {
      self = .null
      return
    }
    if let value = try Self.decodeCandidate(Bool.self, from: container) {
      self = .bool(value)
      return
    }
    if let value = try Self.decodeCandidate(Double.self, from: container) {
      self = .number(value)
      return
    }
    if let value = try Self.decodeCandidate(String.self, from: container) {
      self = .string(value)
      return
    }
    if let value = try Self.decodeCandidate([JSONValue].self, from: container) {
      self = .array(value)
      return
    }
    self = .object(try container.decode([String: JSONValue].self))
  }

  /// Attempts one candidate type, reporting a type mismatch as "not this type"
  /// while letting every other decoding failure propagate.
  private static func decodeCandidate<Candidate: Decodable>(
    _ type: Candidate.Type,
    from container: SingleValueDecodingContainer
  ) throws -> Candidate? {
    do {
      return try container.decode(type)
    } catch DecodingError.typeMismatch {
      return nil
    }
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
    case .array(let value):
      try container.encode(value)
    case .bool(let value):
      try container.encode(value)
    case .null:
      try container.encodeNil()
    case .number(let value):
      try container.encode(value)
    case .object(let value):
      try container.encode(value)
    case .string(let value):
      try container.encode(value)
    }
  }
}

// MARK: - MXFP8ConversionOptions

struct MXFP8ConversionOptions: Equatable {
  let sourceDirectory: URL
  let destinationDirectory: URL
  let overwrite: Bool
}

// MARK: - DevTool

extension DevTool {
  /// Converts an unquantized NV-EmbedCode model directory to MX FP8.
  ///
  /// The conversion assembles a complete model directory in a staging path and
  /// moves it into place only once it is fully written, so an interrupted run
  /// never leaves a half-built model where the loader can find it.
  func quantizeNVEmbedMXFP8(_ arguments: [String]) throws {
    Output.debug("quantizeNVEmbedMXFP8 arguments=\(arguments.count)")
    let options = try mxFP8ConversionOptions(arguments)
    try validateMXFP8Conversion(options)

    let stagingDirectory = options.destinationDirectory
      .deletingLastPathComponent()
      .appendingPathComponent(
        ".\(options.destinationDirectory.lastPathComponent).\(UUID().uuidString).tmp"
      )
    var stagingExists = false
    defer {
      if stagingExists {
        removeStagingDirectory(stagingDirectory)
      }
    }

    try fileManager.createDirectory(
      at: stagingDirectory,
      withIntermediateDirectories: true
    )
    stagingExists = true
    try copyNonWeightFiles(
      from: options.sourceDirectory,
      to: stagingDirectory
    )
    try writeMXFP8Configuration(
      at: stagingDirectory.appendingPathComponent("config.json")
    )

    let destinationWeights =
      stagingDirectory
      .appendingPathComponent(consolidatedWeightsName)
    try NVEmbeddingMXFP8Converter.writeQuantizedWeights(
      sourceDirectory: options.sourceDirectory,
      destinationFile: destinationWeights
    )

    if fileManager.fileExists(atPath: options.destinationDirectory.path) {
      try fileManager.removeItem(at: options.destinationDirectory)
    }
    try fileManager.moveItem(
      at: stagingDirectory,
      to: options.destinationDirectory
    )
    stagingExists = false
    Output.notice("mxfp8 converted destination=\(options.destinationDirectory.path)")
    try writeLine("[quantize-nv-embed-mxfp8] \(options.destinationDirectory.path)")
  }

  /// Removes the staging directory, reporting a failure rather than dropping it.
  ///
  /// A leftover staging directory is recoverable, so this does not throw, but a
  /// silent failure would leave many gigabytes on disk with no explanation.
  private func removeStagingDirectory(_ stagingDirectory: URL) {
    do {
      try fileManager.removeItem(at: stagingDirectory)
    } catch {
      Output.error(
        "mxfp8 staging cleanup failed path=\(stagingDirectory.path) error=\(error)"
      )
    }
  }

  func mxFP8ConversionOptions(_ arguments: [String]) throws -> MXFP8ConversionOptions {
    var sourceDirectory = homeDirectory()
      .appendingPathComponent(".lmstudio/models/nvidia/NV-EmbedCode-7b-v1")
    var destinationDirectory: URL?
    var overwrite = false
    var argumentIndex = 0

    while argumentIndex < arguments.count {
      let argument = arguments[argumentIndex]
      switch argument {
      case "--source":
        argumentIndex += 1
        guard argumentIndex < arguments.count else {
          throw ToolError.usage("--source requires a path")
        }
        sourceDirectory = modelDirectoryURL(arguments[argumentIndex])
      case "--destination":
        argumentIndex += 1
        guard argumentIndex < arguments.count else {
          throw ToolError.usage("--destination requires a path")
        }
        destinationDirectory = modelDirectoryURL(arguments[argumentIndex])
      case "--overwrite":
        overwrite = true
      default:
        throw ToolError.usage(
          "unknown quantize-nv-embed-mxfp8 option: \(argument)"
        )
      }
      argumentIndex += 1
    }

    let resolvedDestination: URL
    if let destinationDirectory {
      resolvedDestination = destinationDirectory
    } else {
      resolvedDestination =
        sourceDirectory
        .deletingLastPathComponent()
        .appendingPathComponent(
          sourceDirectory.lastPathComponent + mxFP8DestinationSuffix
        )
    }
    return MXFP8ConversionOptions(
      sourceDirectory: sourceDirectory,
      destinationDirectory: resolvedDestination,
      overwrite: overwrite
    )
  }

  private func modelDirectoryURL(_ path: String) -> URL {
    let expandedPath = (path as NSString).expandingTildeInPath
    return URL(
      fileURLWithPath: expandedPath,
      relativeTo: URL(fileURLWithPath: fileManager.currentDirectoryPath)
    ).standardizedFileURL
  }

  private func validateMXFP8Conversion(_ options: MXFP8ConversionOptions) throws {
    var isSourceDirectory: ObjCBool = false
    guard
      fileManager.fileExists(
        atPath: options.sourceDirectory.path,
        isDirectory: &isSourceDirectory
      ), isSourceDirectory.boolValue
    else {
      throw ToolError.failure(
        "source model directory does not exist: \(options.sourceDirectory.path)"
      )
    }
    if options.sourceDirectory == options.destinationDirectory {
      throw ToolError.failure("source and destination model directories must differ")
    }
    if fileManager.fileExists(atPath: options.destinationDirectory.path),
      !options.overwrite
    {
      throw ToolError.failure(
        "destination exists; pass --overwrite to replace it: "
          + options.destinationDirectory.path
      )
    }
  }

  /// Copies everything except the weights and the shard map that describes them.
  private func copyNonWeightFiles(from source: URL, to destination: URL) throws {
    Output.debug("mxfp8 copy non-weight files source=\(source.path)")
    let resourceKeys: [URLResourceKey] = [.isDirectoryKey]
    guard
      let enumerator = fileManager.enumerator(
        at: source,
        includingPropertiesForKeys: resourceKeys
      )
    else {
      throw ToolError.failure("could not enumerate source model: \(source.path)")
    }

    for case let sourceItem as URL in enumerator {
      if sourceItem.pathExtension == "safetensors" {
        continue
      }
      if sourceItem.lastPathComponent == shardIndexName {
        continue
      }
      let relativePath = String(sourceItem.path.dropFirst(source.path.count + 1))
      let destinationItem = destination.appendingPathComponent(relativePath)
      let resourceValues = try sourceItem.resourceValues(forKeys: Set(resourceKeys))
      if resourceValues.isDirectory == true {
        try fileManager.createDirectory(
          at: destinationItem,
          withIntermediateDirectories: true
        )
      } else {
        try fileManager.copyItem(at: sourceItem, to: destinationItem)
      }
    }
  }

  /// Records the quantization parameters in the destination model config.
  private func writeMXFP8Configuration(at configURL: URL) throws {
    Output.debug("mxfp8 write configuration path=\(configURL.path)")
    let data = try Data(contentsOf: configURL)
    guard
      case .object(var configuration) = try JSONDecoder().decode(
        JSONValue.self,
        from: data
      )
    else {
      throw ToolError.failure("model config must contain a JSON object: \(configURL.path)")
    }
    configuration["quantization"] = .object([
      "group_size": .number(Double(mxFP8GroupSize)),
      "bits": .number(Double(mxFP8Bits)),
      "mode": .string(mxFP8Mode),
    ])
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let output = try encoder.encode(JSONValue.object(configuration))
    try output.write(to: configURL, options: .atomic)
  }
}
