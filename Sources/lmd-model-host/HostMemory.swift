//
//  HostMemory.swift
//  lmd-model-host
//
//  Reads this process's resident footprint. GPU figures are filled by the MLX
//  path in Phase 2; Phase 1 reports RSS and zero GPU.
//

import Darwin
import Foundation
import SwiftLMHostProtocol

enum HostMemory {
  /// Resident set size of this process in bytes, via `task_info`.
  static func currentStats() -> BackendStats {
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(
      MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
    let result = withUnsafeMutablePointer(to: &info) {
      $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
        task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
      }
    }
    let rss = result == KERN_SUCCESS ? Int64(info.resident_size) : 0
    return BackendStats(rssBytes: rss, gpuActiveBytes: 0, gpuCacheBytes: 0)
  }
}
