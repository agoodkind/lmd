//
//  HostMemory.swift
//  lmd-model-host
//
//  Reads this process's resident footprint and MLX GPU memory. Each host has
//  its own MLX allocator in its own address space, so these figures are this
//  process's alone and the broker feeds them into headroom and eviction.
//

import Darwin
import Foundation
import MLX
import SwiftLMHostProtocol

enum HostMemory {
  /// Resident set size in bytes and MLX GPU active/cache bytes. RSS comes from
  /// `task_info`; the GPU figures come from MLX's allocator snapshot, where
  /// `activeMemory` is bytes held by live MLXArrays and `cacheMemory` is the
  /// reusable buffer pool not yet returned to the system.
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
    let snapshot = MLX.Memory.snapshot()
    return BackendStats(
      rssBytes: rss,
      gpuActiveBytes: Int64(snapshot.activeMemory),
      gpuCacheBytes: Int64(snapshot.cacheMemory)
    )
  }
}
