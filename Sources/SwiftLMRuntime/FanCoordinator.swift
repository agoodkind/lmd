//
//  FanCoordinator.swift
//  SwiftLMRuntime
//
//  Created by Alex Goodkind <alex@goodkind.io> on 2026-04-18.
//  Copyright © 2026
//

import AppLogger
import Foundation

private let log = AppLogger.logger(category: "FanCoordinator")

// MARK: - Configuration

/// Configuration knobs for ``FanCoordinator``.
///
/// All numeric constants that gate fan behavior live here so the
/// orchestrator can be reasoned about (and unit-tested) without diving
/// into the implementation.
public struct FanCoordinatorConfig: Sendable {
  /// Absolute path to the `smcfan` CLI binary.
  public let smcfanBinary: String
  /// Fan indices to drive. Empty = observe only.
  public let fanIndices: [Int]
  /// Temperature-to-RPM curve used during the cooling state.
  public let curve: [FanCurvePoint]
  /// Minimum upward RPM delta that justifies a write.
  public let rampUpMinDelta: Int
  /// Minimum downward RPM delta that justifies a write.
  public let rampDownMinDelta: Int
  /// Minimum seconds between two consecutive writes for the same fan.
  public let minSecondsBetweenChanges: TimeInterval
  /// Upper ceiling for cooling-phase time. After this, hand off to auto.
  public let coolOffMaxSeconds: TimeInterval
  /// Temperature threshold that ends the cooling phase early.
  public let coolOffTempC: Double
  /// EMA alpha for load signals (0 = no smoothing, 1 = instantaneous).
  public let loadEmaAlpha: Double
  /// EMA alpha for temp signals.
  public let tempEmaAlpha: Double
  /// Hard temperature (raw, not smoothed) that bypasses rate limiting.
  public let emergencyTempC: Double
  /// Baseline RPM applied on startup so fans don't drop to zero.
  public let startupBaselineRpm: Int
  /// Low RPM written on release right before flipping fans to auto.
  /// Without this, SMC retains the last high manual target so any
  /// fancurveagent we relaunch reads 10k on boot and never recovers.
  public let releaseBaselineRpm: Int

  public init(
    smcfanBinary: String,
    fanIndices: [Int] = [0, 1],
    curve: [FanCurvePoint] = FanCoordinatorConfig.defaultCurve,
    rampUpMinDelta: Int = 500,
    rampDownMinDelta: Int = 1500,
    minSecondsBetweenChanges: TimeInterval = 45,
    coolOffMaxSeconds: TimeInterval = 600,
    coolOffTempC: Double = 60,
    loadEmaAlpha: Double = 0.20,
    tempEmaAlpha: Double = 0.25,
    emergencyTempC: Double = 90,
    startupBaselineRpm: Int = 4000,
    releaseBaselineRpm: Int = 1500
  ) {
    self.smcfanBinary = smcfanBinary
    self.fanIndices = fanIndices
    self.curve = curve
    self.rampUpMinDelta = rampUpMinDelta
    self.rampDownMinDelta = rampDownMinDelta
    self.minSecondsBetweenChanges = minSecondsBetweenChanges
    self.coolOffMaxSeconds = coolOffMaxSeconds
    self.coolOffTempC = coolOffTempC
    self.loadEmaAlpha = loadEmaAlpha
    self.tempEmaAlpha = tempEmaAlpha
    self.emergencyTempC = emergencyTempC
    self.startupBaselineRpm = startupBaselineRpm
    self.releaseBaselineRpm = releaseBaselineRpm
  }

  public static let defaultCurve: [FanCurvePoint] = [
    .init(tempC: 50, rpm: 2500),
    .init(tempC: 65, rpm: 3500),
    .init(tempC: 72, rpm: 4800),
    .init(tempC: 78, rpm: 6000),
    .init(tempC: 85, rpm: 7500),
    .init(tempC: 92, rpm: 9000),
    .init(tempC: 95, rpm: 10000),
  ]
}

/// One (temperature, RPM) knee in the fan curve.
public struct FanCurvePoint: Sendable, Equatable {
  public let tempC: Double
  public let rpm: Int
  public init(tempC: Double, rpm: Int) {
    self.tempC = tempC
    self.rpm = rpm
  }
}

// MARK: - State

/// Fan-control state machine.
///
/// `idle` means fans are back on SMC/FanCurve agent. `active` means we're
/// pegged to a high RPM because inference is in progress. `cooling` is a
/// transitional state that keeps fans running until temps drop.
public enum FanState: String, Sendable {
  case idle
  case active
  case cooling
}

// MARK: - Input signal bundle

/// Thermometry + load signals sampled once per monitor tick.
public struct FanInputs: Sendable {
  public let cpuTempC: Double
  public let gpuTempC: Double
  public let cpuPercent: Double
  public let gpuPercent: Double
  public let pressureFreePct: Int
  public let llmLoaded: Bool

  public init(
    cpuTempC: Double,
    gpuTempC: Double,
    cpuPercent: Double = 0,
    gpuPercent: Double = 0,
    pressureFreePct: Int = 100,
    llmLoaded: Bool = false
  ) {
    self.cpuTempC = cpuTempC
    self.gpuTempC = gpuTempC
    self.cpuPercent = cpuPercent
    self.gpuPercent = gpuPercent
    self.pressureFreePct = pressureFreePct
    self.llmLoaded = llmLoaded
  }
}

// MARK: - Activity-derived floor

/// Maps activity signals to a minimum RPM that preempts thermal rise.
///
/// Exposed as a free function so tests can validate the mapping without
/// owning a FanCoordinator.
public func activityFloorRpm(
  cpuPercent: Double,
  gpuPercent: Double,
  pressureFreePct: Int,
  llmActive: Bool
) -> Int {
  var floor = 0
  if gpuPercent >= 80 { floor = max(floor, 4500) }
  else if gpuPercent >= 50 { floor = max(floor, 3800) }
  else if gpuPercent >= 25 { floor = max(floor, 3200) }

  if cpuPercent >= 70 { floor = max(floor, 4200) }
  else if cpuPercent >= 40 { floor = max(floor, 3500) }

  if pressureFreePct <= 10 { floor = max(floor, 4500) }
  else if pressureFreePct <= 25 { floor = max(floor, 3800) }

  if llmActive {
    if gpuPercent >= 50 { floor = max(floor, 5800) }
    else if gpuPercent >= 25 { floor = max(floor, 5000) }
    else { floor = max(floor, 4200) }
  }
  return floor
}

// MARK: - Linear interpolation across the curve

/// Pick an RPM for a given temperature using linear interpolation.
public func rpmForTemp(_ temp: Double, curve: [FanCurvePoint]) -> Int {
  guard let first = curve.first, let last = curve.last else { return 0 }
  if temp <= first.tempC { return first.rpm }
  if temp >= last.tempC { return last.rpm }
  for i in 0..<(curve.count - 1) {
    let a = curve[i]
    let b = curve[i + 1]
    if temp >= a.tempC && temp <= b.tempC {
      let span = b.tempC - a.tempC
      let ratio = (temp - a.tempC) / span
      return Int(Double(a.rpm) + ratio * Double(b.rpm - a.rpm))
    }
  }
  return last.rpm
}

// MARK: - Coordinator

/// Drives fan hardware based on temperature and activity signals.
///
/// The coordinator is **not thread-safe**. Call `apply` from a single
/// thread (typically the sensor monitor's sample loop). Calls that go to
/// the SMC binary are synchronous `Process` invocations; callers should
/// pick a cadence that matches their monitor interval (15 s works fine).
public final class FanCoordinator {
  public let config: FanCoordinatorConfig

  // State machine
  private(set) public var state: FanState = .idle
  private var coolingStartedAt: Date?
  private var handedToAuto: Bool = false

  // EMA-smoothed signals
  private var smoothCpuPct: Double = 0
  private var smoothGpuPct: Double = 0
  private var smoothCpuTempC: Double = 0
  private var smoothGpuTempC: Double = 0

  // Rate-limit bookkeeping
  private var lastAppliedRpm: [Int: Int] = [:]
  private var lastChangeTime: [Int: Date] = [:]

  /// Optional shell runner. Tests can inject a stub to avoid touching SMC.
  public typealias ShellRunner = (_ path: String, _ args: [String]) -> Int32
  private let runShell: ShellRunner

  /// Optional plain-text sink for callers that want to mirror lifecycle
  /// messages into their own logging pipeline. Most callers no longer
  /// need this because `FanCoordinator` already emits structured events
  /// through the shared `os.Logger` (subsystem `io.goodkind.lmd`,
  /// category `FanCoordinator`).
  private let logSink: (String) -> Void

  public init(
    config: FanCoordinatorConfig,
    runShell: @escaping ShellRunner = FanCoordinator.defaultShell,
    log: @escaping (String) -> Void = { _ in }
  ) {
    self.config = config
    self.runShell = runShell
    self.logSink = log
  }

  // MARK: - Lifecycle

  /// Take over fans. Stops `fancurveagent`, pins a safe baseline RPM.
  public func takeOver() {
    log.notice("fan.coordinator_taking_over baseline_rpm=\(self.config.startupBaselineRpm, privacy: .public)")
    let uid = getuid()
    _ = runShell("/bin/launchctl", ["bootout", "gui/\(uid)/io.goodkind.fancurveagent"])
    _ = runShell("/usr/bin/pkill", ["-9", "-f", "fancurveagent"])
    Thread.sleep(forTimeInterval: 0.5)
    let baseline = config.startupBaselineRpm
    for f in config.fanIndices {
      _ = runShell(config.smcfanBinary, ["set", "\(f)", "\(baseline)"])
      lastAppliedRpm[f] = baseline
      lastChangeTime[f] = Date()
    }
    logSink("fan coordinator took over (baseline \(baseline) rpm)")
  }

  /// Hand fans back to auto and reload the launchd agent if present.
  public func release() {
    log.notice("fan.coordinator_releasing")
    // Bug: SMC retains the last manual RPM target when we flip to auto,
    // so fancurveagent reads a 10k baseline on next boot and holds it.
    // Write a low safe RPM first, THEN flip to auto, THEN reload the
    // launchd agent. The low write clears the stale register and the
    // auto flip cedes control to the system fan controller.
    for f in config.fanIndices {
      _ = runShell(config.smcfanBinary, ["set", "\(f)", "\(config.releaseBaselineRpm)"])
      _ = runShell(config.smcfanBinary, ["auto", "\(f)"])
    }
    lastAppliedRpm.removeAll()
    lastChangeTime.removeAll()
    let uid = getuid()
    let plist = NSString(string: "~/Library/LaunchAgents/io.goodkind.fancurveagent.plist")
      .expandingTildeInPath
    if FileManager.default.fileExists(atPath: plist) {
      _ = runShell("/bin/launchctl", ["bootstrap", "gui/\(uid)", plist])
    }
    logSink("fan coordinator released, fans back to auto")
  }

  // MARK: - Tick

  /// Feed one sample of inputs into the coordinator.
  public func apply(_ inputs: FanInputs, now: Date = Date()) {
    // EMA smoothing
    let a = config.loadEmaAlpha
    let t = config.tempEmaAlpha
    smoothCpuPct = a * inputs.cpuPercent + (1 - a) * smoothCpuPct
    smoothGpuPct = a * inputs.gpuPercent + (1 - a) * smoothGpuPct
    smoothCpuTempC = t * inputs.cpuTempC + (1 - t) * smoothCpuTempC
    smoothGpuTempC = t * inputs.gpuTempC + (1 - t) * smoothGpuTempC

    // State transitions.
    //
    // Historically this required `llmLoaded && smoothGpuPct >= 20` so
    // that "warm but idle" models did not force fans high. The gate
    // raced against EMA smoothing: real inference would start, GPU
    // would jump to 80% instantaneously, but `smoothGpuPct` needed
    // several 2s ticks to climb past 20. By then the request was done,
    // the cooling timer started, fans flipped back to Auto before any
    // physical RPM spin-up. Net effect: fans never actually engaged
    // during short completions.
    //
    // New rule: llmLoaded alone is enough. A preloaded idle model does
    // not set llmLoaded (in-flight is 0). Only in-flight requests
    // raise the flag, so the "warm but idle" case stays safely in
    // the idle state.
    let llmActive = inputs.llmLoaded
    switch state {
    case .idle:
      if llmActive {
        state = .active
        handedToAuto = false
        log.info("fan.state_changed from=idle to=active")
        logSink("fan state: idle -> active")
      }
    case .active:
      if !llmActive {
        state = .cooling
        coolingStartedAt = now
        log.info("fan.state_changed from=active to=cooling")
        logSink("fan state: active -> cooling")
      }
    case .cooling:
      if llmActive {
        state = .active
        coolingStartedAt = nil
        log.info("fan.state_changed from=cooling to=active")
        logSink("fan state: cooling -> active")
      } else {
        let maxTemp = max(smoothCpuTempC, smoothGpuTempC)
        let elapsed = coolingStartedAt.map { now.timeIntervalSince($0) } ?? 0
        let tempOk = maxTemp <= config.coolOffTempC
        let timeUp = elapsed >= config.coolOffMaxSeconds
        if tempOk || timeUp {
          state = .idle
          coolingStartedAt = nil
          let why = tempOk
            ? "temp \(Int(maxTemp))C<=\(Int(config.coolOffTempC))C"
            : "timeout"
          log.info("fan.state_changed from=cooling to=idle reason=\(why, privacy: .public)")
          logSink("fan state: cooling -> idle (\(why))")
        }
      }
    }

    if state == .idle {
      if !handedToAuto {
        for f in config.fanIndices {
          _ = runShell(config.smcfanBinary, ["auto", "\(f)"])
        }
        handedToAuto = true
        lastAppliedRpm.removeAll()
        lastChangeTime.removeAll()
      }
      return
    }

    // Compute target RPM
    let targetRpm: Int
    if state == .active {
      targetRpm = 10_000
    } else {
      let maxSmoothTemp = max(smoothCpuTempC, smoothGpuTempC)
      let tempRpm = rpmForTemp(maxSmoothTemp, curve: config.curve)
      let floorRpm = activityFloorRpm(
        cpuPercent: smoothCpuPct,
        gpuPercent: smoothGpuPct,
        pressureFreePct: inputs.pressureFreePct,
        llmActive: false
      )
      targetRpm = max(tempRpm, floorRpm)
    }

    // Emergency bypass
    let rawMaxTemp = max(inputs.cpuTempC, inputs.gpuTempC)
    let emergency = rawMaxTemp >= config.emergencyTempC

    for f in config.fanIndices {
      let prev = lastAppliedRpm[f] ?? -1
      if prev < 0 {
        _ = runShell(config.smcfanBinary, ["set", "\(f)", "\(targetRpm)"])
        lastAppliedRpm[f] = targetRpm
        lastChangeTime[f] = now
        continue
      }
      if !emergency, let last = lastChangeTime[f],
         now.timeIntervalSince(last) < config.minSecondsBetweenChanges {
        continue
      }
      let delta = targetRpm - prev
      if !emergency {
        if delta > 0 && delta < config.rampUpMinDelta { continue }
        if delta < 0 && -delta < config.rampDownMinDelta { continue }
      }
      _ = runShell(config.smcfanBinary, ["set", "\(f)", "\(targetRpm)"])
      lastAppliedRpm[f] = targetRpm
      lastChangeTime[f] = now
    }
  }

  // MARK: - Default shell runner

  /// Synchronous `Process` runner that routes stdout and stderr to `/dev/null`.
  public static func defaultShell(_ path: String, _ args: [String]) -> Int32 {
    let p = Process()
    p.launchPath = path
    p.arguments = args
    p.standardOutput = FileHandle(forWritingAtPath: "/dev/null")
    p.standardError = FileHandle(forWritingAtPath: "/dev/null")
    do {
      try p.run()
      p.waitUntilExit()
      return p.terminationStatus
    } catch {
      return -1
    }
  }
}
