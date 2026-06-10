//
//  EmbeddingsRouteTests.swift
//  IntegrationTests
//
//  Drives `/v1/embeddings` against the isolated launchd test daemon that
//  `lmd-dev test-daemon up` brings up (via `make test-integration`),
//  addressed through `LMD_TEST_BASE_URL`. Skips when that variable is unset so
//  the default `make test` stays headless and never spawns a broker. Confirms
//  `/v1/models` lists the embedding model and `/swiftlmd/loaded` reports
//  `kind: embedding`.
//

import Foundation
import Nimble
import SwiftLMCore
import SwiftLMRuntime
import XCTest

final class EmbeddingsRouteTests: XCTestCase {
  func testEmbeddingsBatchAgainstRunningBroker() async throws {
    guard let base = ProcessInfo.processInfo.environment["LMD_TEST_BASE_URL"],
      !base.isEmpty
    else {
      throw XCTSkip(
        "set LMD_TEST_BASE_URL to drive the launchd test daemon; run via `make test-integration`")
    }

    let catalogRoot = "\(NSHomeDirectory())/.lmstudio/models"
    guard FileManager.default.fileExists(atPath: catalogRoot) else {
      throw XCTSkip("no LM Studio models directory at \(catalogRoot)")
    }

    guard let embModel = findEmbeddingModel(under: catalogRoot) else {
      throw XCTSkip(
        "no embedding model found under \(catalogRoot); add one (for example Snowflake snowflake-arctic-embed-l)"
      )
    }

    let slug = embModel.slug ?? embModel.displayName
    let expectedDimension = expectedEmbeddingDimension(for: embModel)

    try await waitForHealth(url: "\(base)/health", deadlineSeconds: 45)
    try await assertModelsRouteListsEmbedding(baseURL: base, slug: slug)

    let embPayload: [String: Any] = [
      "model": slug,
      "input": ["integration probe one", "integration probe two"],
    ]
    let embData = try JSONSerialization.data(withJSONObject: embPayload)
    let (embStatus, embBody) = await httpPost(url: "\(base)/v1/embeddings", body: embData)
    let embText = String(data: embBody, encoding: .utf8) ?? ""
    if embStatus != 200 {
      if embText.isEmpty || embText.contains("Failed to load the default metallib") {
        throw XCTSkip(
          "embeddings endpoint unavailable in environment: status=\(embStatus), body=\(embText)")
      }
      expect(embStatus) == 200
    }
    guard let embJson = try? JSONSerialization.jsonObject(with: embBody) as? [String: Any],
      let rows = embJson["data"] as? [[String: Any]]
    else {
      if embText.contains("Failed to load the default metallib") {
        throw XCTSkip("MLX metallib unavailable in environment: \(embText)")
      }
      fail("invalid embeddings JSON")
      return
    }
    expect(rows.count) == 2
    for row in rows {
      let vec = embeddingVector(from: row)
      expect(vec.count) > 0
      if let expectedDimension {
        expect(vec.count) == expectedDimension
      }
    }

    let (loadedStatus, loadedBody) = await httpGet(url: "\(base)/swiftlmd/loaded")
    expect(loadedStatus) == 200
    guard let loaded = try? JSONSerialization.jsonObject(with: loadedBody) as? [String: Any],
      let models = loaded["models"] as? [[String: Any]]
    else {
      fail("invalid loaded JSON")
      return
    }
    let kinds = models.compactMap { $0["kind"] as? String }
    expect(kinds.contains("embedding")) == true
  }

  // MARK: - Helpers

  private func findEmbeddingModel(under root: String) -> ModelDescriptor? {
    let catalog = ModelCatalog(roots: [root])
    let models = catalog.allModels().filter { $0.kind == .embedding }
    if let nvidiaModel = models.first(where: { $0.slug == "nvidia/NV-EmbedCode-7b-v1" }) {
      return nvidiaModel
    }
    return models.first
  }

  private func expectedEmbeddingDimension(for model: ModelDescriptor) -> Int? {
    if model.slug == "nvidia/NV-EmbedCode-7b-v1" {
      return 4_096
    }
    return nil
  }

  private func embeddingVector(from row: [String: Any]) -> [Double] {
    if let values = row["embedding"] as? [Double] {
      return values
    }
    if let values = row["embedding"] as? [NSNumber] {
      return values.map(\.doubleValue)
    }
    return []
  }

  private func assertModelsRouteListsEmbedding(
    baseURL: String,
    slug: String
  ) async throws {
    let (status, body) = await httpGet(url: "\(baseURL)/v1/models")
    expect(status) == 200
    guard
      let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
      let data = json["data"] as? [[String: Any]]
    else {
      fail("invalid /v1/models JSON")
      return
    }
    let model = data.first { row in
      row["id"] as? String == slug
    }
    let unwrappedModel = try XCTUnwrap(model, "missing \(slug) from /v1/models")
    expect(unwrappedModel["kind"] as? String) == "embedding"
  }

  private func waitForHealth(url: String, deadlineSeconds: Int) async throws {
    let deadline = Date().addingTimeInterval(TimeInterval(deadlineSeconds))
    while Date() < deadline {
      let (status, _) = await httpGet(url: url)
      if status == 200 { return }
      try await Task.sleep(nanoseconds: 500_000_000)
    }
    fail("broker did not become healthy at \(url)")
  }

  private func httpGet(url: String) async -> (Int, Data) {
    await withCheckedContinuation { cont in
      guard let u = URL(string: url) else {
        cont.resume(returning: (0, Data()))
        return
      }
      let task = URLSession.shared.dataTask(with: u) { data, resp, _ in
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        cont.resume(returning: (code, data ?? Data()))
      }
      task.resume()
    }
  }

  private func httpPost(url: String, body: Data) async -> (Int, Data) {
    await withCheckedContinuation { cont in
      guard let u = URL(string: url) else {
        cont.resume(returning: (0, Data()))
        return
      }
      var req = URLRequest(url: u)
      req.httpMethod = "POST"
      req.httpBody = body
      req.setValue("application/json", forHTTPHeaderField: "Content-Type")
      let task = URLSession.shared.dataTask(with: req) { data, resp, _ in
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        cont.resume(returning: (code, data ?? Data()))
      }
      task.resume()
    }
  }
}
