//
//  MacmonClient.swift
//  SwiftLMMonitor
//
//  Created by Alex Goodkind <alex@goodkind.io> on 2026-04-18.
//  Copyright © 2026
//

import AppLogger
import Foundation

private let log = AppLogger.logger(category: "MacmonClient")

// MARK: - Macmon snapshot

/// Subset of `macmon serve` output we consume.
public struct MacmonSnapshot: Sendable, Equatable {
  public let cpuTempC: Double
  public let gpuTempC: Double
  public let cpuPercent: Double
  public let gpuPercent: Double
  public let cpuPowerW: Double
  public let gpuPowerW: Double
  public let anePowerW: Double
  public let systemPowerW: Double
  public let ramUsedGB: Double

  public static let zero = MacmonSnapshot(
    cpuTempC: 0, gpuTempC: 0,
    cpuPercent: 0, gpuPercent: 0,
    cpuPowerW: 0, gpuPowerW: 0, anePowerW: 0, systemPowerW: 0,
    ramUsedGB: 0
  )
}

// MARK: - Macmon HTTP client

/// Thin HTTP client against the `macmon serve` endpoint.
public final class MacmonClient: Sendable {
  public let host: String
  public let port: Int
  public let timeout: TimeInterval

  public init(host: String = "127.0.0.1", port: Int = 8765, timeout: TimeInterval = 1.5) {
    self.host = host
    self.port = port
    self.timeout = timeout
  }

  /// Fetch the current macmon JSON and map it to a ``MacmonSnapshot``.
  ///
  /// - Returns: A snapshot, or ``MacmonSnapshot/zero`` on any failure so
  ///   the sampler can still emit a row instead of stalling.
  public func fetch() -> MacmonSnapshot {
    guard let url = URL(string: "http://\(host):\(port)/json") else { return .zero }
    let sem = DispatchSemaphore(value: 0)
    let box = MutableBox<[String: Any]?>(nil)
    var req = URLRequest(url: url, timeoutInterval: timeout)
    req.httpMethod = "GET"
    URLSession.shared.dataTask(with: req) { data, _, _ in
      defer { sem.signal() }
      guard let d = data,
            let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any]
      else { return }
      box.value = obj
    }.resume()
    _ = sem.wait(timeout: .now() + timeout + 0.5)
    guard let obj = box.value else { return .zero }

    let temp = obj["temp"] as? [String: Any]
    let cpuTemp = (temp?["cpu_temp_avg"] as? Double) ?? 0
    let gpuTemp = (temp?["gpu_temp_avg"] as? Double) ?? 0
    let cpuPct = ((obj["cpu_usage_pct"] as? Double) ?? 0) * 100
    let gpuPct = ((obj["gpu_usage"] as? [Any])?.last as? Double).map { $0 * 100 } ?? 0
    let cpuPower = (obj["cpu_power"] as? Double) ?? 0
    let gpuPower = (obj["gpu_power"] as? Double) ?? 0
    let sysPower = (obj["sys_power"] as? Double) ?? 0
    let anePower = (obj["ane_power"] as? Double) ?? 0
    let memBytes = ((obj["memory"] as? [String: Any])?["ram_usage"] as? Double) ?? 0
    let ramGB = memBytes / 1_073_741_824

    return MacmonSnapshot(
      cpuTempC: cpuTemp,
      gpuTempC: gpuTemp,
      cpuPercent: cpuPct,
      gpuPercent: gpuPct,
      cpuPowerW: cpuPower,
      gpuPowerW: gpuPower,
      anePowerW: anePower,
      systemPowerW: sysPower,
      ramUsedGB: ramGB
    )
  }
}

// MARK: - Utility

/// Non-Sendable mutable reference cell used to escape a closure capture.
///
/// `Swift.URLSession.dataTask(...)` invokes its completion on an arbitrary
/// queue, so we need a heap box to write into. The closure is called once
/// and joined on by the semaphore, so data-race safety holds in practice.
/// Marked `@unchecked Sendable` to acknowledge the intentional looseness.
final class MutableBox<T>: @unchecked Sendable {
  var value: T
  init(_ value: T) { self.value = value }
}
