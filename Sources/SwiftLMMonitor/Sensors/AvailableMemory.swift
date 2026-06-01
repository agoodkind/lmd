//
//  AvailableMemory.swift
//  SwiftLMMonitor
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-05-31.
//  Copyright © 2026, all rights reserved.
//

import AppLogger
import Foundation

#if canImport(Darwin)
  import Darwin
#endif

private let log = AppLogger.logger(category: "AvailableMemorySensor")

// MARK: - Available memory reading

/// System-wide free memory derived from the kernel's virtual memory counters.
public struct AvailableMemorySnapshot: Sendable, Equatable {
  /// Bytes the system can hand to a new allocation without swapping or
  /// compressing memory that is in active use.
  public let availableBytes: Int64
  /// Total physical memory installed.
  public let totalBytes: Int64

  public init(availableBytes: Int64, totalBytes: Int64) {
    self.availableBytes = availableBytes
    self.totalBytes = totalBytes
  }
}

/// Reads system-wide free memory through `host_statistics64`.
public enum AvailableMemory {
  /// Sum the page groups that the system can reclaim cheaply for a new
  /// allocation. Free, inactive, speculative, and purgeable pages are all
  /// reclaimable without compressing or swapping memory in active use. Active
  /// and wired pages are excluded, and compressed pages are already consumed.
  ///
  /// Exposed as a pure function so the byte math is testable without the
  /// kernel call.
  public static func availableBytes(
    freePages: Int64,
    inactivePages: Int64,
    speculativePages: Int64,
    purgeablePages: Int64,
    pageSizeBytes: Int64
  ) -> Int64 {
    (freePages + inactivePages + speculativePages + purgeablePages) * pageSizeBytes
  }

  /// Read live free memory. On the rare kernel-call failure, fall back to the
  /// system free-percentage sensor so the figure degrades to a trusted source
  /// rather than overstating available memory.
  public static func read() -> AvailableMemorySnapshot {
    let total = Int64(ProcessInfo.processInfo.physicalMemory)

    #if canImport(Darwin)
      var stats = vm_statistics64_data_t()
      var count = mach_msg_type_number_t(
        MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
      let host = mach_host_self()
      let result = withUnsafeMutablePointer(to: &stats) { pointer in
        pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { reboundPointer in
          host_statistics64(host, HOST_VM_INFO64, reboundPointer, &count)
        }
      }

      guard result == KERN_SUCCESS else {
        let freePercent = MemoryPressure.freePercent()
        let approximate = Int64(Double(total) * Double(freePercent) / 100.0)
        log.error(
          "available_memory.host_statistics64_failed kr=\(result, privacy: .public) fallback_free_pct=\(freePercent, privacy: .public)"
        )
        return AvailableMemorySnapshot(availableBytes: approximate, totalBytes: total)
      }

      let pageSize = Int64(sysconf(_SC_PAGESIZE))
      let available = availableBytes(
        freePages: Int64(stats.free_count),
        inactivePages: Int64(stats.inactive_count),
        speculativePages: Int64(stats.speculative_count),
        purgeablePages: Int64(stats.purgeable_count),
        pageSizeBytes: pageSize)
      return AvailableMemorySnapshot(availableBytes: available, totalBytes: total)
    #else
      return AvailableMemorySnapshot(availableBytes: total, totalBytes: total)
    #endif
  }
}
