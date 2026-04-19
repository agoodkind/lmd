import Foundation

private final class AsyncBridgeBox<Value>: @unchecked Sendable {
  private var value: Value?
  private let lock = NSLock()

  init(_ value: Value?) {
    self.value = value
  }

  func set(_ value: Value) {
    lock.lock()
    self.value = value
    lock.unlock()
  }

  func get() -> Value? {
    lock.lock()
    defer { lock.unlock() }
    return value
  }
}

/// Error returned when a blocking async bridge fails to store a result.
enum AsyncBridgeError: Error {
  case missingResult
}

/// Execute an async closure and wait for the return value.
///
/// This helper intentionally mirrors the existing `runBlocking` patterns in
/// this repository so synchronous CLI and XPC entry points can block on
/// async work.
public func runBlocking<Value>(
  _ work: @Sendable @escaping () async throws -> Value
) -> Result<Value, Error> {
  let semaphore = DispatchSemaphore(value: 0)
  let box = AsyncBridgeBox<Result<Value, Error>?>(nil)
  Task.detached {
    do {
      box.set(.success(try await work()))
    } catch {
      box.set(.failure(error))
    }
    semaphore.signal()
  }
  semaphore.wait()
  guard let boxedResult = box.get(),
        let result = boxedResult else {
    return .failure(AsyncBridgeError.missingResult)
  }
  return result
}
