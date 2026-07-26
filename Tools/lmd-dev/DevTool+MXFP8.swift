//
//  DevTool+MXFP8.swift
//  lmd-dev
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-07-25.
//  Copyright © 2026, all rights reserved.
//

import Foundation
import MLX
import SwiftLMEmbed
import SwiftMkCore

private let mxFP8GroupSize = 32
private let mxFP8Bits = 8
private let mxFP8Mode = "mxfp8"
private let affineDefaultGroupSize = 64
private let consolidatedWeightsName = "model.safetensors"

/// An option that takes a value consumes its own name plus that value.
private let argumentsPerValueOption = 2

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

// MARK: - MXFP8ParsedArguments

/// Options as written on the command line, before mode defaults are applied.
struct MXFP8ParsedArguments {
  var sourceDirectory: URL
  var destinationDirectory: URL?
  var overwrite: Bool = false
  var mode: String
  var groupSize: Int?
  var bits: Int?
}

// MARK: - MXFP8ConversionOptions

struct MXFP8ConversionOptions: Equatable {
  let sourceDirectory: URL
  let destinationDirectory: URL
  let overwrite: Bool
  let groupSize: Int
  let bits: Int
  let mode: String
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
    try writeQuantizationConfiguration(
      at: stagingDirectory.appendingPathComponent("config.json"),
      options: options
    )

    let destinationWeights =
      stagingDirectory
      .appendingPathComponent(consolidatedWeightsName)
    try NVEmbeddingMXFP8Converter.writeQuantizedWeights(
      sourceDirectory: options.sourceDirectory,
      destinationFile: destinationWeights,
      groupSize: options.groupSize,
      bits: options.bits,
      mode: try quantizationMode(options.mode)
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

  /// Maps a mode name from the command line onto the MLX quantization mode.
  private func quantizationMode(_ name: String) throws -> QuantizationMode {
    guard let mode = QuantizationMode(rawValue: name) else {
      throw ToolError.usage("unknown quantization mode: \(name)")
    }
    return mode
  }

  func mxFP8ConversionOptions(_ arguments: [String]) throws -> MXFP8ConversionOptions {
    var parsed = MXFP8ParsedArguments(
      sourceDirectory: homeDirectory()
        .appendingPathComponent(".lmstudio/models/nvidia/NV-EmbedCode-7b-v1"),
      mode: mxFP8Mode
    )
    var argumentIndex = 0
    while argumentIndex < arguments.count {
      argumentIndex = try applyArgument(
        arguments,
        at: argumentIndex,
        into: &parsed
      )
    }
    return resolveOptions(parsed)
  }

  /// Applies one option and returns the index of the next one.
  ///
  /// A flag consumes one argument, and an option that takes a value consumes
  /// two: the option name and the value that follows it.
  private func applyArgument(
    _ arguments: [String],
    at index: Int,
    into parsed: inout MXFP8ParsedArguments
  ) throws -> Int {
    let argument = arguments[index]
    switch argument {
    case "--overwrite":
      parsed.overwrite = true
      return index + 1
    case "--source":
      parsed.sourceDirectory = modelDirectoryURL(
        try value(arguments, after: index, describing: "--source requires a path"))
    case "--destination":
      parsed.destinationDirectory = modelDirectoryURL(
        try value(arguments, after: index, describing: "--destination requires a path"))
    case "--mode":
      parsed.mode = try value(
        arguments, after: index, describing: "--mode requires a quantization mode")
    case "--group-size":
      parsed.groupSize = try integer(
        arguments, after: index, describing: "--group-size requires an integer")
    case "--bits":
      parsed.bits = try integer(
        arguments, after: index, describing: "--bits requires an integer")
    default:
      throw ToolError.usage("unknown quantize-nv-embed-mxfp8 option: \(argument)")
    }
    return index + argumentsPerValueOption
  }

  private func value(
    _ arguments: [String],
    after index: Int,
    describing message: String
  ) throws -> String {
    guard index + 1 < arguments.count else {
      throw ToolError.usage(message)
    }
    return arguments[index + 1]
  }

  private func integer(
    _ arguments: [String],
    after index: Int,
    describing message: String
  ) throws -> Int {
    guard let parsed = Int(try value(arguments, after: index, describing: message)) else {
      throw ToolError.usage(message)
    }
    return parsed
  }

  /// Fills in the defaults each mode implies.
  ///
  /// The destination is named after the mode so converting one format never
  /// overwrites another, which matters while formats are being compared.
  private func resolveOptions(_ parsed: MXFP8ParsedArguments) -> MXFP8ConversionOptions {
    let destination =
      parsed.destinationDirectory
      ?? parsed.sourceDirectory
      .deletingLastPathComponent()
      .appendingPathComponent(
        parsed.sourceDirectory.lastPathComponent + "-" + parsed.mode
      )
    return MXFP8ConversionOptions(
      sourceDirectory: parsed.sourceDirectory,
      destinationDirectory: destination,
      overwrite: parsed.overwrite,
      groupSize: parsed.groupSize ?? defaultGroupSize(for: parsed.mode),
      bits: parsed.bits ?? mxFP8Bits,
      mode: parsed.mode
    )
  }

  /// The group size each mode uses unless the caller overrides it.
  ///
  /// MX FP8 is fixed at 32 by the format. Affine defaults to 64, matching MLX's
  /// own default, because a larger group amortizes the per-group scale and bias.
  private func defaultGroupSize(for mode: String) -> Int {
    if mode == mxFP8Mode {
      return mxFP8GroupSize
    }
    return affineDefaultGroupSize
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
  private func writeQuantizationConfiguration(
    at configURL: URL,
    options: MXFP8ConversionOptions
  ) throws {
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
      "group_size": .number(Double(options.groupSize)),
      "bits": .number(Double(options.bits)),
      "mode": .string(options.mode),
    ])
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let output = try encoder.encode(JSONValue.object(configuration))
    try output.write(to: configURL, options: .atomic)
  }
}
