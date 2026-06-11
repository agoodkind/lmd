import Nimble
import XCTest

@testable import lmd_model_host

final class EmbeddingJobQueueTests: XCTestCase {
  func testPriorityAcquiresBeforeEarlierNormalWaiters() async {
    let queue = EmbeddingJobQueue(maxConcurrent: 1, laneEnabled: true)
    let order = OrderRecorder()
    await queue.acquire(priority: false)

    let normal = Task {
      await queue.acquire(priority: false)
      await order.append("normal")
      await queue.release()
    }
    try? await Task.sleep(nanoseconds: 50_000_000)
    let priority = Task {
      await queue.acquire(priority: true)
      await order.append("priority")
      await queue.release()
    }
    try? await Task.sleep(nanoseconds: 50_000_000)

    await queue.release()
    _ = await priority.value
    _ = await normal.value
    let recorded = await order.values
    expect(recorded) == ["priority", "normal"]
  }

  func testLaneDisabledIsStrictFIFO() async {
    let queue = EmbeddingJobQueue(maxConcurrent: 1, laneEnabled: false)
    let order = OrderRecorder()
    await queue.acquire(priority: false)

    let first = Task {
      await queue.acquire(priority: false)
      await order.append("first")
      await queue.release()
    }
    try? await Task.sleep(nanoseconds: 50_000_000)
    let second = Task {
      await queue.acquire(priority: true)
      await order.append("second")
      await queue.release()
    }
    try? await Task.sleep(nanoseconds: 50_000_000)

    await queue.release()
    _ = await first.value
    _ = await second.value
    let recorded = await order.values
    expect(recorded) == ["first", "second"]
  }

  func testMaxConcurrentTwoAdmitsTwoWithoutWaiting() async {
    let queue = EmbeddingJobQueue(maxConcurrent: 2, laneEnabled: true)
    await queue.acquire(priority: false)
    await queue.acquire(priority: false)
    let depth = await queue.waitingCount
    expect(depth) == 0
    await queue.release()
    await queue.release()
  }
}

private actor OrderRecorder {
  private(set) var values: [String] = []

  func append(_ value: String) {
    values.append(value)
  }
}
