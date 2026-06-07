//
//  ChatHost.swift
//  lmd-model-host
//
//  Serves chat requests by supervising the prebuilt SwiftLM binary inside the
//  helper process and proxying OpenAI HTTP response bytes back to the broker as
//  XPC frames. The helper owns the SwiftLM child and stops it on shutdown.
//

import AppLogger
import Darwin
import Foundation
import SwiftLMBackend
import SwiftLMHostProtocol

private let log = AppLogger.logger(category: "ChatHost")

enum ChatHostError: Error, CustomStringConvertible {
  case missingSwiftLMBinaryPath
  case noEphemeralPort
  case swiftLMReadyTimeout(model: String, seconds: TimeInterval)
  case unsupportedEndpoint(String?)
  case serverNotLoaded

  var description: String {
    switch self {
    case .missingSwiftLMBinaryPath:
      return "missing --swiftlm-binary for chat host"
    case .noEphemeralPort:
      return "no ephemeral localhost port available for SwiftLM child"
    case .swiftLMReadyTimeout(let model, let seconds):
      return "SwiftLM child for \(model) did not become ready within \(seconds)s"
    case .unsupportedEndpoint(let endpoint):
      return "unsupported chat endpoint \(endpoint ?? "<missing>")"
    case .serverNotLoaded:
      return "chat server not loaded"
    }
  }
}

actor ChatHost {
  private let modelPath: String
  private let binaryPath: String
  private let logPath: String?
  private let contextLength: Int?
  private var server: SwiftLMServer?
  private var port: Int?

  init(
    modelPath: String,
    binaryPath: String?,
    logPath: String?,
    contextLength: Int?
  ) throws {
    guard let binaryPath, !binaryPath.isEmpty else {
      throw ChatHostError.missingSwiftLMBinaryPath
    }
    self.modelPath = modelPath
    self.binaryPath = binaryPath
    self.logPath = logPath
    self.contextLength = contextLength
  }

  func load() throws {
    let childPort = try reserveEphemeralLocalhostPort()
    let config = SwiftLMServerConfig(
      binaryPath: binaryPath,
      port: childPort,
      logFilePath: logPath
    )
    let childServer = SwiftLMServer(
      model: modelPath,
      contextSize: contextLength,
      config: config,
      log: { message in
        log.notice("chat.child \(message, privacy: .public)")
      }
    )
    try childServer.start()
    guard childServer.waitReady() else {
      childServer.stop()
      throw ChatHostError.swiftLMReadyTimeout(
        model: modelPath,
        seconds: config.readyTimeout
      )
    }
    server = childServer
    port = childPort
    log.notice(
      "chat.loaded model=\(self.modelPath, privacy: .public) child_port=\(childPort, privacy: .public)"
    )
  }

  func shutdown() {
    server?.stop()
    server = nil
    port = nil
  }

  func stats() -> BackendStats {
    guard let processID = server?.process?.processIdentifier else {
      return BackendStats(rssBytes: 0, gpuActiveBytes: 0, gpuCacheBytes: 0)
    }
    return HostMemory.childProcessStats(processID: processID)
  }

  func serve(
    _ request: BackendRequest,
    send: @escaping @Sendable (BackendFrame) -> Void
  ) async {
    do {
      try await proxy(request, send: send)
    } catch {
      send(.failed(requestID: request.requestID, message: "\(error)"))
    }
  }

  private func proxy(
    _ request: BackendRequest,
    send: @escaping @Sendable (BackendFrame) -> Void
  ) async throws {
    guard let port else {
      throw ChatHostError.serverNotLoaded
    }
    let endpointPath = try validatedEndpointPath(request.endpointPath)
    guard let url = URL(string: "http://localhost:\(port)\(endpointPath)") else {
      throw ChatHostError.unsupportedEndpoint(request.endpointPath)
    }
    var upstreamRequest = URLRequest(url: url, timeoutInterval: 600)
    upstreamRequest.httpMethod = "POST"
    upstreamRequest.httpBody = request.openAIBody
    upstreamRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
    for (field, value) in request.headers {
      upstreamRequest.setValue(value, forHTTPHeaderField: field)
    }
    if request.stream {
      upstreamRequest.setValue("text/event-stream", forHTTPHeaderField: "Accept")
      try await proxyStreaming(request, upstreamRequest: upstreamRequest, send: send)
      return
    }
    try await proxyBuffered(request, upstreamRequest: upstreamRequest, send: send)
  }

  private func proxyStreaming(
    _ request: BackendRequest,
    upstreamRequest: URLRequest,
    send: @escaping @Sendable (BackendFrame) -> Void
  ) async throws {
    let (bytes, response) = try await URLSession.shared.bytes(for: upstreamRequest)
    let httpResponse = response as? HTTPURLResponse
    let statusCode = httpResponse?.statusCode ?? 502
    let contentType =
      httpResponse?.value(forHTTPHeaderField: "Content-Type") ?? "text/event-stream"
    send(
      .responseStarted(
        requestID: request.requestID,
        statusCode: statusCode,
        contentType: contentType
      ))

    var iterator = bytes.makeAsyncIterator()
    let chunkSize = 4096
    while true {
      try Task.checkCancellation()
      var rawBytes: [UInt8] = []
      rawBytes.reserveCapacity(chunkSize)
      while rawBytes.count < chunkSize {
        try Task.checkCancellation()
        guard let byte = try await iterator.next() else {
          break
        }
        rawBytes.append(byte)
      }
      if rawBytes.isEmpty {
        send(.done(requestID: request.requestID))
        return
      }
      send(.chunk(requestID: request.requestID, data: Data(rawBytes)))
    }
  }

  private func proxyBuffered(
    _ request: BackendRequest,
    upstreamRequest: URLRequest,
    send: @escaping @Sendable (BackendFrame) -> Void
  ) async throws {
    let (data, response) = try await URLSession.shared.data(for: upstreamRequest)
    let httpResponse = response as? HTTPURLResponse
    let statusCode = httpResponse?.statusCode ?? 502
    let contentType = httpResponse?.value(forHTTPHeaderField: "Content-Type") ?? "application/json"
    send(
      .responseStarted(
        requestID: request.requestID,
        statusCode: statusCode,
        contentType: contentType
      ))
    send(.chunk(requestID: request.requestID, data: data))
    send(.done(requestID: request.requestID))
  }

  private func validatedEndpointPath(_ endpointPath: String?) throws -> String {
    switch endpointPath {
    case "/v1/chat/completions", "/v1/completions":
      return endpointPath ?? ""
    default:
      throw ChatHostError.unsupportedEndpoint(endpointPath)
    }
  }
}

private func reserveEphemeralLocalhostPort() throws -> Int {
  let descriptor = socket(AF_INET, SOCK_STREAM, 0)
  guard descriptor >= 0 else {
    throw ChatHostError.noEphemeralPort
  }
  defer {
    close(descriptor)
  }

  var reuse: Int32 = 1
  setsockopt(
    descriptor,
    SOL_SOCKET,
    SO_REUSEADDR,
    &reuse,
    socklen_t(MemoryLayout<Int32>.size)
  )

  var address = sockaddr_in()
  address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
  address.sin_family = sa_family_t(AF_INET)
  address.sin_port = in_port_t(0).bigEndian
  address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

  let bindResult = withUnsafePointer(to: &address) { pointer in
    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { rebound in
      bind(descriptor, rebound, socklen_t(MemoryLayout<sockaddr_in>.size))
    }
  }
  guard bindResult == 0 else {
    throw ChatHostError.noEphemeralPort
  }

  var boundAddress = sockaddr_in()
  var boundLength = socklen_t(MemoryLayout<sockaddr_in>.size)
  let nameResult = withUnsafeMutablePointer(to: &boundAddress) { pointer in
    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { rebound in
      getsockname(descriptor, rebound, &boundLength)
    }
  }
  guard nameResult == 0 else {
    throw ChatHostError.noEphemeralPort
  }
  return Int(UInt16(bigEndian: boundAddress.sin_port))
}
