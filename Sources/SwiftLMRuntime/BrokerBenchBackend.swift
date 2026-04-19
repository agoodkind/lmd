//
//  BrokerBenchBackend.swift
//  SwiftLMRuntime
//
//  Created by Alex Goodkind <alex@goodkind.io> on 2026-04-18.
//  Copyright © 2026
//
//  Concrete `BenchBackend` that drives a running `swiftlmd` broker over
//  HTTP. Preload, chat, and unload all go through the broker's public
//  API. This means:
//
//   - `lmd bench run configs.json` works against any broker, local or remote
//   - The bench process does not spawn SwiftLM itself; the broker handles it
//   - Memory budget / eviction / fan control live on the broker side
//
//  Tests continue to use the existing `FakeBackend` in-memory stub so no
//  HTTP is exercised at unit-test time.
//

import AppLogger
import Foundation

private let log = AppLogger.logger(category: "BrokerBenchBackend")

// MARK: - BrokerBenchBackend

public final class BrokerBenchBackend: BenchBackend, @unchecked Sendable {
  public let brokerBase: String
  public let session: URLSession

  private let lock = NSLock()
  private var loadedModels: Set<String> = []

  public init(
    brokerHost: String = "127.0.0.1",
    brokerPort: Int = 5400,
    session: URLSession = .shared
  ) {
    self.brokerBase = "http://\(brokerHost):\(brokerPort)"
    self.session = session
  }

  // MARK: - BenchBackend

  public func loadIfNeeded(_ model: BenchModelSpec) throws {
    lock.lock()
    if loadedModels.contains(model.id) {
      lock.unlock()
      return
    }
    lock.unlock()

    let body = try JSONSerialization.data(withJSONObject: ["model": model.id])
    let (status, data) = postSync(path: "/swiftlmd/preload", body: body, timeout: 600)
    if !(200..<300).contains(status) {
      let text = String(data: data, encoding: .utf8) ?? "status \(status)"
      throw BrokerError.preloadFailed(model: model.id, message: text)
    }
    lock.lock()
    loadedModels.insert(model.id)
    lock.unlock()
  }

  public func runChat(
    model: BenchModelSpec,
    variant: BenchVariant,
    systemPrompt: String,
    userContent: String,
    timeout: TimeInterval
  ) async throws -> Data {
    let messages: [[String: Any]] = [
      ["role": "system", "content": systemPrompt],
      ["role": "user", "content": userContent],
    ]
    let maxTokens = model.maxTokensOverride ?? variant.maxTokens
    var body: [String: Any] = [
      "model": model.id,
      "messages": messages,
      "max_tokens": maxTokens,
      "stream": false,
    ]
    if variant.thinking {
      // Signal to the broker that the caller wants thinking mode. The
      // broker doesn't currently act on this flag, but carrying it in
      // the request body preserves round-trip fidelity for debugging.
      body["thinking"] = true
    }
    let bodyData = try JSONSerialization.data(withJSONObject: body)

    let (status, data) = try await postAsync(
      path: "/v1/chat/completions", body: bodyData, timeout: timeout
    )
    if !(200..<300).contains(status) {
      let text = String(data: data, encoding: .utf8) ?? "status \(status)"
      throw BrokerError.chatFailed(status: status, message: text)
    }
    return data
  }

  public func unload(_ model: BenchModelSpec) {
    guard let body = try? JSONSerialization.data(withJSONObject: ["model": model.id]) else { return }
    _ = postSync(path: "/swiftlmd/unload", body: body, timeout: 30)
    lock.lock()
    loadedModels.remove(model.id)
    lock.unlock()
  }

  // MARK: - Errors

  public enum BrokerError: Error, CustomStringConvertible {
    case preloadFailed(model: String, message: String)
    case chatFailed(status: Int, message: String)
    case badURL

    public var description: String {
      switch self {
      case .preloadFailed(let model, let message):
        return "preload failed for \(model): \(message)"
      case .chatFailed(let status, let message):
        return "chat failed (HTTP \(status)): \(message)"
      case .badURL:
        return "bad URL"
      }
    }
  }

  // MARK: - HTTP helpers

  private func postSync(path: String, body: Data, timeout: TimeInterval) -> (Int, Data) {
    guard let url = URL(string: "\(brokerBase)\(path)") else { return (0, Data()) }
    var req = URLRequest(url: url, timeoutInterval: timeout)
    req.httpMethod = "POST"
    req.httpBody = body
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    let sem = DispatchSemaphore(value: 0)
    let box = MutableBox<(Int, Data)>((0, Data()))
    session.dataTask(with: req) { data, resp, _ in
      defer { sem.signal() }
      let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
      box.value = (status, data ?? Data())
    }.resume()
    _ = sem.wait(timeout: .now() + timeout + 5)
    return box.value
  }

  private func postAsync(path: String, body: Data, timeout: TimeInterval) async throws -> (Int, Data) {
    guard let url = URL(string: "\(brokerBase)\(path)") else { throw BrokerError.badURL }
    var req = URLRequest(url: url, timeoutInterval: timeout)
    req.httpMethod = "POST"
    req.httpBody = body
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    let (data, resp) = try await session.data(for: req)
    let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
    return (status, data)
  }
}

// MARK: - MutableBox (local duplicate to avoid cross-module visibility)

private final class MutableBox<T>: @unchecked Sendable {
  var value: T
  init(_ value: T) { self.value = value }
}
