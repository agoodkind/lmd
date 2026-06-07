//
//  XPCChatBackend.swift
//  LMDServeSupport
//
//  Adapts a `ModelServer` chat host reached over XPC to the chat router's
//  existing SwiftLM backend protocol and to the broker's BackendChatResult
//  rendering path. The host owns SwiftLM HTTP proxying; this adapter only sends
//  the OpenAI body and rebuilds the HTTP response from metadata plus raw chunks.
//

import Foundation
import SwiftLMHostProtocol
import SwiftLMRuntime

public enum XPCChatBackendError: Error, Equatable {
  case hostFailed(message: String)
  case missingResponseStarted
  case launchResultMissing
}

private struct XPCChatResponseHeader: Sendable {
  let statusCode: Int
  let contentType: String
}

private actor XPCChatHeaderBox {
  private var result: Result<XPCChatResponseHeader, Error>?
  private var waiters: [CheckedContinuation<XPCChatResponseHeader, Error>] = []

  func wait() async throws -> XPCChatResponseHeader {
    if let result {
      return try result.get()
    }
    return try await withCheckedThrowingContinuation { continuation in
      waiters.append(continuation)
    }
  }

  func succeed(_ header: XPCChatResponseHeader) {
    complete(.success(header))
  }

  func fail(_ error: Error) {
    complete(.failure(error))
  }

  private func complete(_ nextResult: Result<XPCChatResponseHeader, Error>) {
    guard result == nil else {
      return
    }
    result = nextResult
    let continuations = waiters
    waiters.removeAll()
    for continuation in continuations {
      continuation.resume(with: nextResult)
    }
  }
}

private final class AsyncVoidResultBox: @unchecked Sendable {
  var result: Result<Void, Error>?
}

public final class XPCChatBackend: SwiftLMBackendProtocol, @unchecked Sendable {
  private let server: ModelServer
  private let onShutdown: @Sendable () -> Void

  public let port: Int
  public var modelID: String { server.modelID }
  public var sizeBytes: Int64 { server.sizeBytes }
  public var isRunning: Bool { server.isRunning }

  public init(
    server: ModelServer,
    port: Int,
    onShutdown: @escaping @Sendable () -> Void = {}
  ) {
    self.server = server
    self.port = port
    self.onShutdown = onShutdown
  }

  public func launch() throws {
    do {
      try waitForAsyncLaunch {
        try await self.server.spawn()
        try await self.server.waitReady()
      }
    } catch {
      onShutdown()
      throw error
    }
  }

  public func shutdown() {
    server.shutdown()
    onShutdown()
  }

  public func complete(
    _ request: PreparedChatRequest,
    requestID: UUID,
    headers: [String: String]
  ) async throws -> BackendChatResult {
    let backendRequest = BackendRequest(
      requestID: requestID,
      kind: .chat,
      openAIBody: request.bodyData,
      stream: request.wantsStream,
      endpointPath: request.endpoint.path,
      headers: headers
    )
    if request.wantsStream {
      return try await streamingResult(frames: server.send(backendRequest))
    }
    return try await bufferedResult(frames: server.send(backendRequest))
  }

  private func bufferedResult(
    frames: AsyncThrowingStream<BackendFrame, Error>
  ) async throws -> BackendChatResult {
    var header: XPCChatResponseHeader?
    var body = Data()
    for try await frame in frames {
      switch frame {
      case .responseStarted(_, let statusCode, let contentType):
        header = XPCChatResponseHeader(statusCode: statusCode, contentType: contentType)
      case .chunk(_, let data):
        body.append(data)
      case .failed(_, let message):
        throw XPCChatBackendError.hostFailed(message: message)
      case .done:
        guard let header else {
          throw XPCChatBackendError.missingResponseStarted
        }
        return .buffered(
          statusCode: header.statusCode,
          contentType: "application/json",
          body: body
        )
      default:
        continue
      }
    }
    throw XPCChatBackendError.missingResponseStarted
  }

  private func streamingResult(
    frames: AsyncThrowingStream<BackendFrame, Error>
  ) async throws -> BackendChatResult {
    let headerBox = XPCChatHeaderBox()
    let events = AsyncThrowingStream<BackendStreamEvent, Error> { continuation in
      let task = Task {
        var sawHeader = false
        do {
          for try await frame in frames {
            switch frame {
            case .responseStarted(_, let statusCode, let contentType):
              sawHeader = true
              await headerBox.succeed(
                XPCChatResponseHeader(statusCode: statusCode, contentType: contentType))
            case .chunk(_, let data):
              continuation.yield(.rawBytes(data))
            case .failed(_, let message):
              let error = XPCChatBackendError.hostFailed(message: message)
              if !sawHeader {
                await headerBox.fail(error)
              }
              continuation.finish(throwing: error)
              return
            case .done:
              if !sawHeader {
                await headerBox.fail(XPCChatBackendError.missingResponseStarted)
                continuation.finish(throwing: XPCChatBackendError.missingResponseStarted)
                return
              }
              continuation.finish()
              return
            default:
              continue
            }
          }
          if !sawHeader {
            await headerBox.fail(XPCChatBackendError.missingResponseStarted)
            continuation.finish(throwing: XPCChatBackendError.missingResponseStarted)
            return
          }
          continuation.finish()
        } catch {
          if !sawHeader {
            await headerBox.fail(error)
          }
          continuation.finish(throwing: error)
        }
      }
      continuation.onTermination = { @Sendable _ in
        task.cancel()
      }
    }
    let header = try await headerBox.wait()
    return .streaming(
      statusCode: header.statusCode,
      contentType: header.contentType,
      events: events,
      appendDoneFrame: false,
      lifetimeToken: nil
    )
  }

  private func waitForAsyncLaunch(
    _ operation: @escaping @Sendable () async throws -> Void
  ) throws {
    let semaphore = DispatchSemaphore(value: 0)
    let box = AsyncVoidResultBox()
    Task {
      do {
        try await operation()
        box.result = .success(())
      } catch {
        box.result = .failure(error)
      }
      semaphore.signal()
    }
    semaphore.wait()
    guard let result = box.result else {
      throw XPCChatBackendError.launchResultMissing
    }
    try result.get()
  }
}
