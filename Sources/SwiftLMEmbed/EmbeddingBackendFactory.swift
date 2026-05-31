//
//  EmbeddingBackendFactory.swift
//  SwiftLMEmbed
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-05-17.
//  Copyright © 2026, all rights reserved.
//

import AppLogger
import Foundation
import SwiftLMBackend
import SwiftLMCore

private let log = AppLogger.logger(category: "EmbeddingBackendFactory")

public enum EmbeddingBackendFamily: Equatable, Sendable {
  case mlx
  case nvidiaMistralBidirectional(NVEmbeddingMetadata)
}

public enum EmbeddingBackendSelectionError: Equatable, Sendable, UnsupportedEmbeddingBackendError {
  case notEmbeddingModel(modelID: String)
  case missingConfig(modelID: String, path: String)
  case invalidConfig(modelID: String, path: String)
  case unsupportedEmbeddingBackend(
    modelID: String,
    modelType: String?,
    architectures: [String]
  )
  case unsupportedNVPooling(modelID: String, poolingMode: NVEmbeddingPoolingMode)

  public var description: String {
    switch self {
    case .notEmbeddingModel(let modelID):
      return "model \(modelID) is not an embedding model"
    case .missingConfig(let modelID, let path):
      return "embedding model \(modelID) is missing config.json at \(path)"
    case .invalidConfig(let modelID, let path):
      return "embedding model \(modelID) has invalid config.json at \(path)"
    case .unsupportedEmbeddingBackend(let modelID, let modelType, let architectures):
      let typeText = modelType ?? "unknown"
      let architectureText = architectures.isEmpty ? "none" : architectures.joined(separator: ",")
      return "unsupported embedding backend for \(modelID): model_type=\(typeText) architectures=\(architectureText)"
    case .unsupportedNVPooling(let modelID, let poolingMode):
      return "unsupported NVIDIA embedding pooling for \(modelID): \(poolingMode.rawValue)"
    }
  }
}

public enum EmbeddingBackendFactory {
  public static func makeBackend(descriptor: ModelDescriptor) throws -> EmbeddingBackendProtocol {
    let family = try EmbeddingBackendSelector.select(descriptor: descriptor)
    switch family {
    case .mlx:
      log.info("embedding.backend_selected model=\(descriptor.id, privacy: .public) backend=mlx")
      return MLXEmbeddingBackend(descriptor: descriptor)
    case .nvidiaMistralBidirectional(let metadata):
      log.info("embedding.backend_selected model=\(descriptor.id, privacy: .public) backend=nvidia_mistral_bidirectional")
      return NVEmbeddingBackend(descriptor: descriptor, metadata: metadata)
    }
  }
}

public enum EmbeddingBackendSelector {
  public static func select(descriptor: ModelDescriptor) throws -> EmbeddingBackendFamily {
    guard descriptor.kind == .embedding else {
      throw EmbeddingBackendSelectionError.notEmbeddingModel(modelID: descriptor.id)
    }

    let config = try EmbeddingConfigFile.load(modelID: descriptor.id, modelDir: descriptor.path)
    if config.isNVIDIAMistralBidirectional {
      let metadata = try NVEmbeddingMetadata.load(
        modelID: descriptor.id,
        modelDir: descriptor.path,
        config: config
      )
      guard metadata.poolingMode == .meanTokens else {
        throw EmbeddingBackendSelectionError.unsupportedNVPooling(
          modelID: descriptor.id,
          poolingMode: metadata.poolingMode
        )
      }
      return .nvidiaMistralBidirectional(metadata)
    }

    if config.isMLXCompatibleEmbedding {
      return .mlx
    }

    throw EmbeddingBackendSelectionError.unsupportedEmbeddingBackend(
      modelID: descriptor.id,
      modelType: config.modelType,
      architectures: config.architectures
    )
  }
}

struct EmbeddingConfigFile: Equatable, Sendable {
  let modelType: String?
  let architectures: [String]
  let autoModel: String?

  var isNVIDIAMistralBidirectional: Bool {
    let normalizedType = modelType?.lowercased()
    let hasArchitecture = architectures.contains { architecture in
      architecture.caseInsensitiveCompare("MistralBiDirectionalModel") == .orderedSame
    }
    let hasAutoModel = autoModel?.contains("MistralBiDirectionalModel") == true
    return normalizedType == "mistralbidirectional" && (hasArchitecture || hasAutoModel)
  }

  var isMLXCompatibleEmbedding: Bool {
    guard let modelType else {
      return architectures.contains(where: Self.mlxCompatibleArchitecture)
    }
    let compatibleTypes: Set<String> = [
      "bert",
      "distilbert",
      "gemma3",
      "gemma3_text",
      "gemma3n",
      "nomic_bert",
      "qwen3",
      "roberta",
      "xlm-roberta",
    ]
    if compatibleTypes.contains(modelType.lowercased()) {
      return true
    }
    return architectures.contains(where: Self.mlxCompatibleArchitecture)
  }

  static func load(modelID: String, modelDir: String) throws -> EmbeddingConfigFile {
    let path = "\(modelDir)/config.json"
    guard FileManager.default.fileExists(atPath: path) else {
      throw EmbeddingBackendSelectionError.missingConfig(modelID: modelID, path: path)
    }
    guard
      let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else {
      throw EmbeddingBackendSelectionError.invalidConfig(modelID: modelID, path: path)
    }
    let autoMap = object["auto_map"] as? [String: Any]
    return EmbeddingConfigFile(
      modelType: object["model_type"] as? String,
      architectures: object["architectures"] as? [String] ?? [],
      autoModel: autoMap?["AutoModel"] as? String
    )
  }

  private static func mlxCompatibleArchitecture(_ architecture: String) -> Bool {
    let prefixes = [
      "Bert",
      "GTE",
      "JinaBert",
      "MPNet",
      "NomicBert",
      "RobertaForMaskedLM",
      "SnowflakeArcticEmbed",
      "XLMRoberta",
    ]
    return prefixes.contains { prefix in
      architecture.range(of: prefix, options: [.caseInsensitive, .anchored]) != nil
    }
  }
}
