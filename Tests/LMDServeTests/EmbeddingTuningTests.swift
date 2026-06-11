import Nimble
import XCTest

@testable import LMDServeSupport

final class EmbeddingTuningTests: XCTestCase {
  private let gib: Int64 = 1_073_741_824

  func testCacheAutoIsLargestPowerOfTwoGiBUnderOneEighthFree() {
    // 73 GiB free means 73/8 = 9.1 GiB, so 8 GiB (the spec's on-machine example).
    expect(EmbeddingTuningResolver.resolveCacheLimitBytes(
      explicitGB: nil, freeMemoryBytes: 73 * self.gib)) == Int(8 * self.gib)
  }

  func testCacheAutoClampsLowAndHigh() {
    expect(EmbeddingTuningResolver.resolveCacheLimitBytes(
      explicitGB: nil, freeMemoryBytes: 4 * self.gib)) == Int(2 * self.gib)
    expect(EmbeddingTuningResolver.resolveCacheLimitBytes(
      explicitGB: nil, freeMemoryBytes: 512 * self.gib)) == Int(16 * self.gib)
  }

  func testExplicitCacheWinsOverAuto() {
    expect(EmbeddingTuningResolver.resolveCacheLimitBytes(
      explicitGB: 4, freeMemoryBytes: 73 * self.gib)) == Int(4 * self.gib)
  }

  func testTransientBytesPerSlotFormula() {
    // dtype x (4 x intermediate + 8 x hidden) = 2 x (4x14336 + 8x4096) = 180224
    expect(EmbeddingTuningResolver.transientBytesPerSlot(
      hiddenSize: 4_096, intermediateSize: 14_336, dtypeBytes: 2)) == 180_224
  }

  func testBudgetAutoFitsTwiceTransientsInCacheRoundedTo1024() {
    // 8 GiB / (2 x 180224) = 23831, so 23552 (multiple of 1024), within [2048, 32768].
    expect(EmbeddingTuningResolver.resolveSlotBudget(
      explicit: nil, cacheLimitBytes: Int(8 * self.gib), transientBytesPerSlot: 180_224)) == 23_552
  }

  func testBudgetAutoClamps() {
    expect(EmbeddingTuningResolver.resolveSlotBudget(
      explicit: nil, cacheLimitBytes: Int(2 * self.gib), transientBytesPerSlot: 4_000_000)) == 2_048
    expect(EmbeddingTuningResolver.resolveSlotBudget(
      explicit: nil, cacheLimitBytes: Int(16 * self.gib), transientBytesPerSlot: 1_000)) == 32_768
  }

  func testExplicitBudgetWins() {
    expect(EmbeddingTuningResolver.resolveSlotBudget(
      explicit: 8_192, cacheLimitBytes: Int(2 * self.gib), transientBytesPerSlot: 180_224)) == 8_192
  }
}
