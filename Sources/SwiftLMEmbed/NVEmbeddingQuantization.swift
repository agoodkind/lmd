//
//  NVEmbeddingQuantization.swift
//  SwiftLMEmbed
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-07-25.
//  Copyright © 2026, all rights reserved.
//

import AppLogger
import Foundation
import MLX
import MLXLMCommon
import MLXNN

private let log = AppLogger.logger(category: "NVEmbeddingQuantization")

/// MX FP8 stores one shared 8-bit exponent per group of 32 elements, so the
/// core rejects any other pairing. Validating here turns a malformed model
/// `config.json` into a named error instead of a failure deep inside Metal.
private let mxFP8GroupSize = 32
private let mxFP8Bits = 8

// MARK: - NVEmbeddingQuantizationError

enum NVEmbeddingQuantizationError: Error, Equatable, Sendable, CustomStringConvertible {
  case invalidBits(Int)
  case invalidGroupSize(Int)

  var description: String {
    switch self {
    case .invalidBits(let value):
      return "MX FP8 quantization requires bits \(mxFP8Bits), got \(value)"
    case .invalidGroupSize(let value):
      return "MX FP8 quantization requires group_size \(mxFP8GroupSize), got \(value)"
    }
  }
}

// MARK: - NVEmbeddingQuantization

/// Quantization support for the NV-EmbedCode embedding weights.
///
/// Loading and conversion deliberately use different mechanisms. Conversion
/// decides which layers to quantize, because no checkpoint exists yet. Loading
/// derives that decision from the checkpoint itself, because `loadWeights`
/// quantizes exactly the layers whose weights carry a `scales` entry. Deriving
/// it means the loader can never disagree with the checkpoint it reads.
enum NVEmbeddingQuantization {
  /// Validates a quantization block read from a model's `config.json`.
  ///
  /// A `nil` block means the model is unquantized and loads unchanged.
  static func validate(_ quantization: BaseConfiguration.Quantization?) throws {
    guard let quantization, quantization.mode == .mxfp8 else {
      return
    }
    if quantization.groupSize != mxFP8GroupSize {
      throw NVEmbeddingQuantizationError.invalidGroupSize(quantization.groupSize)
    }
    if quantization.bits != mxFP8Bits {
      throw NVEmbeddingQuantizationError.invalidBits(quantization.bits)
    }
  }

  /// The layers converted to MX FP8.
  ///
  /// Only `Linear` layers are quantized. They hold 6.98 of the model's 7.11
  /// billion parameters, so they carry essentially all of the size win. The
  /// token embedding table is left at full precision: it is 1.8 percent of the
  /// parameters, so quantizing it saves little, and every downstream layer
  /// reads its output, so error introduced there propagates through the whole
  /// forward pass.
  static func shouldQuantize(path _: String, module: Module) -> Bool {
    module is Linear
  }

  /// Quantizes a freshly constructed model tree for conversion to MX FP8.
  static func applyForConversion(to model: Module) {
    quantize(
      model: model,
      groupSize: mxFP8GroupSize,
      bits: mxFP8Bits,
      mode: .mxfp8,
      filter: shouldQuantize(path:module:)
    )
    log.info(
      """
      nv_embedding.quantized_for_conversion mode=\(QuantizationMode.mxfp8.rawValue, privacy: .public) \
      group_size=\(mxFP8GroupSize, privacy: .public) bits=\(mxFP8Bits, privacy: .public)
      """
    )
  }
}

// MARK: - NVEmbeddingMXFP8ConversionError

public enum NVEmbeddingMXFP8ConversionError:
  Error,
  Equatable,
  Sendable,
  CustomStringConvertible
{
  case sourceAlreadyQuantized

  public var description: String {
    switch self {
    case .sourceAlreadyQuantized:
      return "MX FP8 conversion requires an unquantized source model"
    }
  }
}

// MARK: - NVEmbeddingMXFP8Converter

public enum NVEmbeddingMXFP8Converter {
  /// Reads the unquantized weights from `sourceDirectory`, quantizes them to
  /// MX FP8, and writes a single consolidated safetensors file.
  ///
  /// The source directory is never modified.
  public static func writeQuantizedWeights(
    sourceDirectory: URL,
    destinationFile: URL
  ) throws {
    let configData = try Data(
      contentsOf: sourceDirectory.appendingPathComponent("config.json")
    )
    let modelConfiguration = try JSONDecoder().decode(
      NVMistralBiDirectionalConfiguration.self,
      from: configData
    )
    if modelConfiguration.quantization != nil {
      throw NVEmbeddingMXFP8ConversionError.sourceAlreadyQuantized
    }

    let model = NVMistralBiDirectionalModel(modelConfiguration)
    try loadWeights(modelDirectory: sourceDirectory, model: model)
    NVEmbeddingQuantization.applyForConversion(to: model)

    let parameters = Dictionary(uniqueKeysWithValues: model.parameters().flattened())
    eval(parameters.values)
    try MLX.save(arrays: parameters, url: destinationFile)
  }
}
