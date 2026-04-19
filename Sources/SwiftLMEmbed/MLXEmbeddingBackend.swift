//
//  MLXEmbeddingBackend.swift
//  SwiftLMEmbed
//
//  Created by Alex Goodkind <alex@goodkind.io> on 2026-04-19.
//  Copyright © 2026
//

import Foundation
import MLX
import MLXEmbedders
import SwiftLMBackend
import SwiftLMCore

public enum MLXEmbeddingRuntimeError: Error {
  case modelNotLoaded
}

/// Loads weights from ``ModelDescriptor/path`` via MLXEmbedders and runs batched pooling.
public final class MLXEmbeddingBackend: EmbeddingBackendProtocol, @unchecked Sendable {
  private let descriptor: ModelDescriptor
  private var container: MLXEmbedders.ModelContainer?

  public var modelID: String { descriptor.id }
  public var sizeBytes: Int64 { descriptor.sizeBytes }

  public init(descriptor: ModelDescriptor) {
    self.descriptor = descriptor
  }

  public func launch() async throws {
    let configuration = ModelConfiguration(directory: URL(fileURLWithPath: descriptor.path))
    container = try await loadModelContainer(configuration: configuration)
  }

  public func shutdown() {
    container = nil
  }

  public func embed(inputs: [String]) async throws -> [[Float]] {
    guard let container else {
      throw MLXEmbeddingRuntimeError.modelNotLoaded
    }
    return await container.perform { model, tokenizer, pooling in
      let encoded = inputs.map { tokenizer.encode(text: $0, addSpecialTokens: true) }
      let maxLength = encoded.reduce(into: 1) { acc, elem in
        acc = max(acc, elem.count)
      }
      let padId = tokenizer.eosTokenId ?? 0
      let padded = stacked(
        encoded.map { elem in
          MLXArray(
            elem + Array(repeating: padId, count: maxLength - elem.count))
        })
      let mask = (padded .!= padId)
      let tokenTypes = MLXArray.zeros(like: padded)
      let modelOutput = model(
        padded, positionIds: nil, tokenTypeIds: tokenTypes, attentionMask: mask)
      let result = pooling(modelOutput, normalize: true, applyLayerNorm: true)
      result.eval()
      let batchCount = result.shape[0]
      var rows: [[Float]] = []
      rows.reserveCapacity(batchCount)
      for i in 0..<batchCount {
        rows.append(result[i].asArray(Float.self))
      }
      return rows
    }
  }
}
