import Nimble
import XCTest

@testable import lmd_model_host

final class EmbeddingSlicePlanTests: XCTestCase {
  func testRangesCloseBeforeTheTokenLimit() {
    let counts = [600, 600, 600, 600, 600]
    let ranges = EmbeddingSlicePlan.ranges(tokenCounts: counts, maxTokens: 1_500)
    expect(ranges) == [0..<2, 2..<4, 4..<5]
  }

  func testAnInputAboveTheLimitGetsItsOwnRange() {
    let ranges = EmbeddingSlicePlan.ranges(tokenCounts: [100, 5_000, 100], maxTokens: 1_500)
    expect(ranges) == [0..<1, 1..<2, 2..<3]
  }

  func testEveryInputIsInExactlyOneRange() {
    let counts = [10, 2_000, 30, 40, 1_990, 5, 5, 3_000, 1]
    let ranges = EmbeddingSlicePlan.ranges(tokenCounts: counts, maxTokens: 2_048)
    expect(ranges.flatMap { Array($0) }) == Array(counts.indices)
  }

  func testNoInputsProduceNoRange() {
    expect(EmbeddingSlicePlan.ranges(tokenCounts: [], maxTokens: 2_048)).to(beEmpty())
  }

  func testAPriorityWaiterAcquiresTheSlotBetweenTwoSlices() async throws {
    let queue = EmbeddingJobQueue(maxConcurrent: 1, laneEnabled: true)
    let order = SliceOrderRecorder()
    await queue.acquire(priority: false)
    await order.append("slice 1")

    let query = Task {
      await queue.acquire(priority: true)
      await order.append("query")
      await queue.release()
    }
    try await Task.sleep(nanoseconds: 50_000_000)

    await queue.release()
    await queue.acquire(priority: false)
    await order.append("slice 2")
    await queue.release()
    _ = await query.value

    let recorded = await order.values
    expect(recorded) == ["slice 1", "query", "slice 2"]
  }
}

// MARK: - SliceOrderRecorder

private actor SliceOrderRecorder {
  private(set) var values: [String] = []

  func append(_ value: String) {
    values.append(value)
  }
}
