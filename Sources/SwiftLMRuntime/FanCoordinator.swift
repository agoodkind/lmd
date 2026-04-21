//
//  FanCoordinator.swift
//  SwiftLMRuntime
//

import AppLogger
import Foundation

private let log = AppLogger.logger(category: "FanCoordinator")

// MARK: - Configuration

/// Configuration knobs for ``FanCoordinator``.
public struct FanCoordinatorConfig: Sendable {
  /// Fan indices to drive. Empty = observe only.
  public let fanIndices: [Int]
  /// Temperature-to-RPM curve used during the cooling state.
  public let curve: [FanCurvePoint]
  /// Minimum upward RPM delta that justifies a write (outside ramp windows).
  public let rampUpMinDelta: Int
  /// Minimum downward RPM delta that justifies a write (outside ramp windows).
  public let rampDownMinDelta: Int
  /// Minimum seconds between two consecutive writes for the same fan (steady state).
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
  public let releaseBaselineRpm: Int
  /// Seconds to ramp from current RPM to the active steady target when LLM becomes active.
  public let activeRampDuration: TimeInterval
  /// Seconds fans hold the active-target RPM after LLM unload before the cooling ramp starts.
  public let holdSeconds: TimeInterval
  /// Seconds to ramp down from the held RPM toward the steady cooling target after the hold window.
  public let coolingRampDownSeconds: TimeInterval
  /// Smoothed max(CPU, GPU) temp at or above this requests 10_000 RPM while active.
  public let activeFullBlastTempC: Double
  /// Minimum interval between writes while an active or cooling ramp is in progress.
  public let rampMinSecondsBetweenChanges: TimeInterval
  /// When SMC max RPM cannot be read, use this value as the recorded max.
  public let fallbackMaxRpm: Int
  /// smcd priority used while the coordinator is in `.active`. Matches
  /// `SMCDPriority.llmActive`. Preempts fancurveagent's curve output.
  public let activePriority: Int
  /// smcd priority used while the coordinator is in `.cooling` (both hold
  /// and ramp down). Matches `SMCDPriority.llmCooling`. Stays above
  /// fancurveagent normal priority but lets user boost (priority 50)
  /// preempt during cooling.
  public let coolingPriority: Int

  public init(
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
    releaseBaselineRpm: Int = 1500,
    activeRampDuration: TimeInterval = 15,
    holdSeconds: TimeInterval = 90,
    coolingRampDownSeconds: TimeInterval = 180,
    activeFullBlastTempC: Double = 75,
    rampMinSecondsBetweenChanges: TimeInterval = 0.5,
    fallbackMaxRpm: Int = 9000,
    activePriority: Int = 50,
    coolingPriority: Int = 20
  ) {
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
    self.activeRampDuration = activeRampDuration
    self.holdSeconds = holdSeconds
    self.coolingRampDownSeconds = coolingRampDownSeconds
    self.activeFullBlastTempC = activeFullBlastTempC
    self.rampMinSecondsBetweenChanges = rampMinSecondsBetweenChanges
    self.fallbackMaxRpm = fallbackMaxRpm
    self.activePriority = activePriority
    self.coolingPriority = coolingPriority
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

private func lerpInt(_ a: Int, _ b: Int, _ t: Double) -> Int {
  if t <= 0 { return a }
  if t >= 1 { return b }
  return a + Int((Double(b - a) * t).rounded())
}

// MARK: - Coordinator

/// Drives fan hardware based on temperature and activity signals.
public final class FanCoordinator: @unchecked Sendable {
  public let config: FanCoordinatorConfig

  private(set) public var state: FanState = .idle
  private var coolingStartedAt: Date?
  private var handedToAuto: Bool = false

  /// Fans that survived takeover and are eligible for writes. Starts as
  /// `config.fanIndices` and shrinks as individual fans fail or time out.
  private var activeFanIndices: [Int] = []

  private var smoothCpuPct: Double = 0
  private var smoothGpuPct: Double = 0
  private var smoothCpuTempC: Double = 0
  private var smoothGpuTempC: Double = 0

  private var lastAppliedRpm: [Int: Int] = [:]
  private var lastChangeTime: [Int: Date] = [:]

  private var smcMaxRpmByFan: [Int: Int] = [:]
  private var activeRampStartedAt: Date?
  private var activeStartRpm: [Int: Int] = [:]
  private var coolingStartRpm: [Int: Int] = [:]

  private let smc: FanSMCControlling
  private let logSink: (String) -> Void

  public init(
    config: FanCoordinatorConfig,
    smc: FanSMCControlling,
    log: @escaping (String) -> Void = { _ in }
  ) {
    self.config = config
    self.smc = smc
    self.logSink = log
    self.activeFanIndices = config.fanIndices
  }

  /// Synchronous `Process` runner for `launchctl` / `pkill` only.
  public static func runLaunchProcess(_ path: String, _ args: [String]) -> Int32 {
    log.debug("fan.process_run path=\(path, privacy: .public) args=\(args.joined(separator: ","), privacy: .public)")
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    p.standardOutput = FileHandle(forWritingAtPath: "/dev/null")
    p.standardError = FileHandle(forWritingAtPath: "/dev/null")
    do {
      try p.run()
      p.waitUntilExit()
      log.debug("fan.process_exit path=\(path, privacy: .public) exit_status=\(p.terminationStatus, privacy: .public)")
      return p.terminationStatus
    } catch {
      log.error("fan.process_failed path=\(path, privacy: .public) error=\(String(describing: error), privacy: .public)")
      return -1
    }
  }

  // MARK: - Lifecycle

  /// Take over fans. Writes a safe baseline RPM through smcd. Arbitration
  /// with fancurveagent is handled by smcd; no launchctl bootout required.
  public func takeOver() {
    log.notice(
      "fan.coordinator_taking_over baseline_rpm=\(self.config.startupBaselineRpm, privacy: .public) fan_indices=\(self.config.fanIndices, privacy: .public)"
    )

    activeFanIndices = self.config.fanIndices
    smcMaxRpmByFan.removeAll()

    do {
      try smc.smcOpenIfNeededSync()
    } catch {
      log.error(
        "fan.takeover_smc_open_failed error=\(String(describing: error), privacy: .public)"
      )
      activeFanIndices.removeAll()
      logSink("fan coordinator: SMC open failed, fan policy disabled")
      return
    }

    for f in self.config.fanIndices {
      log.notice("fan.baseline_iteration fan=\(f, privacy: .public)")
      do {
        let maxRpm = try smc.readFanMaxRpmSync(fanIndex: f)
        log.debug("fan.max_rpm_read fan=\(f, privacy: .public) max_rpm=\(maxRpm, privacy: .public)")
        smcMaxRpmByFan[f] = maxRpm
      } catch {
        log.error(
          "fan.max_rpm_read_failed fan=\(f, privacy: .public) error=\(String(describing: error), privacy: .public)"
        )
        smcMaxRpmByFan[f] = self.config.fallbackMaxRpm
      }
      do {
        try smc.setRpmSync(fanIndex: f, rpm: self.config.startupBaselineRpm)
        log.notice(
          "fan.baseline_set fan=\(f, privacy: .public) target=\(self.config.startupBaselineRpm, privacy: .public)"
        )
        lastAppliedRpm[f] = self.config.startupBaselineRpm
        lastChangeTime[f] = Date()
      } catch {
        // The helper often applies the SMC write but fails to reply. Log and
        // continue: the tick loop will reassert the target every 500ms against
        // the reconnecting client, and the state machine still owns the fan.
        log.error(
          "fan.baseline_set_failed fan=\(f, privacy: .public) target=\(self.config.startupBaselineRpm, privacy: .public) error=\(String(describing: error), privacy: .public)"
        )
        lastAppliedRpm[f] = self.config.startupBaselineRpm
        lastChangeTime[f] = Date()
      }
    }

    handedToAuto = true
    log.notice(
      "fan.takeover_complete healthy_fans=\(self.activeFanIndices, privacy: .public)"
    )

    logSink("fan coordinator took over (baseline \(self.config.startupBaselineRpm) rpm)")
  }

  /// Hand fans back to auto and reload the launchd agent if present.
  public func release() {
    let releaseIndices = self.activeFanIndices.isEmpty ? self.config.fanIndices : self.activeFanIndices
    log.notice(
      "fan.coordinator_releasing fan_indices=\(releaseIndices, privacy: .public)"
    )
    do {
      for f in releaseIndices {
        do {
          try smc.setRpmSync(fanIndex: f, rpm: self.config.releaseBaselineRpm)
          log.debug(
            "fan.release_set_fallback fan=\(f, privacy: .public) rpm=\(self.config.releaseBaselineRpm, privacy: .public)"
          )
          try smc.setAutoSync(fanIndex: f)
          log.info("fan.release_auto fan=\(f, privacy: .public)")
        } catch {
          log.error(
            "fan.release_fan_failed fan=\(f, privacy: .public) error=\(String(describing: error), privacy: .public)"
          )
          throw error
        }
      }
      try smc.closeSMCConnectionSync()
      log.debug("fan.release_smc_closed")
    } catch {
      log.error("fan.release_smc_failed error=\(String(describing: error), privacy: .public)")
    }
    lastAppliedRpm.removeAll()
    lastChangeTime.removeAll()
    // smcd and fancurveagent coexist through arbitration; no launchd
    // bootstrap needed here. If fancurveagent is installed and running
    // it keeps running, and takes over fan ownership via TTL once lmd
    // stops writing.
    logSink("fan coordinator released, fans back to auto")
  }

  // MARK: - Tick

  /// Feed one sample of inputs into the coordinator.
  public func apply(_ inputs: FanInputs, now: Date = Date()) async throws {
    let previousState = self.state
    if self.activeFanIndices.isEmpty {
      log.debug(
        "fan.apply_no_healthy_fans configured=\(self.config.fanIndices, privacy: .public)"
      )
      return
    }

    let a = self.config.loadEmaAlpha
    let t = self.config.tempEmaAlpha
    smoothCpuPct = a * inputs.cpuPercent + (1 - a) * smoothCpuPct
    smoothGpuPct = a * inputs.gpuPercent + (1 - a) * smoothGpuPct
    smoothCpuTempC = t * inputs.cpuTempC + (1 - t) * smoothCpuTempC
    smoothGpuTempC = t * inputs.gpuTempC + (1 - t) * smoothGpuTempC
    log.debug(
      "fan.apply_inputs_ema cpu_percent=\(inputs.cpuPercent, privacy: .public) gpu_percent=\(inputs.gpuPercent, privacy: .public) cpu_temp=\(inputs.cpuTempC, privacy: .public) gpu_temp=\(inputs.gpuTempC, privacy: .public)"
    )
    log.debug(
      "fan.apply_inputs_ema smooth_cpu_temp=\(self.smoothCpuTempC, privacy: .public) smooth_gpu_temp=\(self.smoothGpuTempC, privacy: .public) smooth_cpu_pct=\(self.smoothCpuPct, privacy: .public) smooth_gpu_pct=\(self.smoothGpuPct, privacy: .public)"
    )

    let llmActive = inputs.llmLoaded
    log.debug(
      "fan.apply_state_transition from=\(previousState.rawValue, privacy: .public) llm_loaded=\(llmActive, privacy: .public)"
    )
    switch self.state {
    case .idle:
      if llmActive {
        enterActive(now: now)
      }
    case .active:
      if !llmActive {
        enterCooling(now: now)
      }
    case .cooling:
      if llmActive {
        reenterActiveFromCooling(now: now)
        log.info("fan.state_changed from=cooling to=active")
        logSink("fan state: cooling -> active")
      } else {
        let maxTemp = max(self.smoothCpuTempC, self.smoothGpuTempC)
        let elapsed = coolingStartedAt.map { now.timeIntervalSince($0) } ?? 0
        let rampComplete = elapsed >= (self.config.holdSeconds + self.config.coolingRampDownSeconds)
        let tempOk = maxTemp <= self.config.coolOffTempC
        let timeUp = elapsed >= self.config.coolOffMaxSeconds
        if rampComplete && (tempOk || timeUp) {
          state = .idle
          coolingStartedAt = nil
          handedToAuto = false
          let why = tempOk
            ? "temp \(Int(maxTemp))C<=\(Int(self.config.coolOffTempC))C"
            : "timeout"
          log.info("fan.state_changed from=cooling to=idle reason=\(why, privacy: .public)")
          logSink("fan state: cooling -> idle (\(why))")
        } else {
          log.debug(
            "fan.cooling_hold max_temp=\(maxTemp, privacy: .public) elapsed=\(elapsed, privacy: .public) ramp_complete=\(rampComplete, privacy: .public) temp_threshold=\(self.config.coolOffTempC, privacy: .public) timeout_seconds=\(self.config.coolOffMaxSeconds, privacy: .public)"
          )
        }
      }
    }

    log.debug("fan.apply_state after_transition=\(self.state.rawValue, privacy: .public) from=\(previousState.rawValue, privacy: .public)")

    if self.state == .idle {
      if !self.handedToAuto {
        for f in self.activeFanIndices {
          log.debug("fan.auto_set fan=\(f, privacy: .public)")
          do {
            try await smc.setAuto(fanIndex: f)
            log.info("fan.auto_set_success fan=\(f, privacy: .public)")
          } catch {
            log.error("fan.auto_set_failed fan=\(f, privacy: .public) error=\(String(describing: error), privacy: .public)")
          }
        }
        self.handedToAuto = true
        lastAppliedRpm.removeAll()
        lastChangeTime.removeAll()
        log.debug("fan.auto_complete")
      }
      return
    }

    let rawMaxTemp = max(inputs.cpuTempC, inputs.gpuTempC)
    let emergency = rawMaxTemp >= self.config.emergencyTempC
    log.debug("fan.temp_eval raw_max_temp=\(rawMaxTemp, privacy: .public) emergency=\(emergency, privacy: .public)")

    let maxSmooth = max(smoothCpuTempC, smoothGpuTempC)
    let hotEnoughForFullBlast = maxSmooth >= self.config.activeFullBlastTempC

    let inActiveRampWindow = self.state == .active && !hotEnoughForFullBlast
      && self.activeRampStartedAt.map({ now.timeIntervalSince($0) < self.config.activeRampDuration }) == true

    let coolingElapsed = self.coolingStartedAt.map({ now.timeIntervalSince($0) }) ?? .infinity
    let inHoldWindow = self.state == .cooling && coolingElapsed < self.config.holdSeconds
    let inCoolingRampWindow = self.state == .cooling
      && coolingElapsed >= self.config.holdSeconds
      && coolingElapsed < (self.config.holdSeconds + self.config.coolingRampDownSeconds)

    let inRampPhase = inActiveRampWindow || inHoldWindow || inCoolingRampWindow
    log.debug(
      "fan.ramp_eval state=\(self.state.rawValue, privacy: .public) active_ramp=\(inActiveRampWindow, privacy: .public) hold=\(inHoldWindow, privacy: .public) cooling_ramp=\(inCoolingRampWindow, privacy: .public) in_ramp_phase=\(inRampPhase, privacy: .public)"
    )

    let activeSteady = activeSteadyTarget(inputs: inputs)
    let steadyCooling = steadyCoolingTarget(inputs: inputs)
    log.debug("fan.steady_target active=\(activeSteady, privacy: .public) cooling=\(steadyCooling, privacy: .public)")

    for f in self.activeFanIndices {
      let targetRpm: Int
      if self.state == .active {
        if emergency || hotEnoughForFullBlast {
          targetRpm = 10_000
        } else if let rampStart = activeRampStartedAt,
                  now.timeIntervalSince(rampStart) < self.config.activeRampDuration {
          let elapsed = now.timeIntervalSince(rampStart)
          let rampT = min(1, elapsed / self.config.activeRampDuration)
          let start = self.activeStartRpm[f] ?? self.config.startupBaselineRpm
          targetRpm = lerpInt(start, activeSteady, rampT)
        } else {
          targetRpm = activeSteady
        }
      } else {
        let holdRpm = coolingStartRpm[f] ?? steadyCooling
        if coolingElapsed < self.config.holdSeconds {
          targetRpm = holdRpm
        } else if coolingElapsed < (self.config.holdSeconds + self.config.coolingRampDownSeconds) {
          let rampElapsed = coolingElapsed - self.config.holdSeconds
          let rampT = min(1, rampElapsed / self.config.coolingRampDownSeconds)
          targetRpm = lerpInt(holdRpm, steadyCooling, rampT)
        } else {
          targetRpm = steadyCooling
        }
      }
      log.debug(
      "fan.target_calc fan=\(f, privacy: .public) state=\(self.state.rawValue, privacy: .public) target_rpm=\(targetRpm, privacy: .public)"
      )

      let prev = self.lastAppliedRpm[f] ?? -1
      if prev < 0 {
        log.debug("fan.target_apply_first fan=\(f, privacy: .public) target_rpm=\(targetRpm, privacy: .public)")
        do {
          try await smc.setRpm(fanIndex: f, rpm: targetRpm)
          lastAppliedRpm[f] = targetRpm
          lastChangeTime[f] = now
          log.info("fan.rpm_set fan=\(f, privacy: .public) rpm=\(targetRpm, privacy: .public)")
        } catch {
          log.error("fan.set_rpm_failed fan=\(f, privacy: .public) target_rpm=\(targetRpm, privacy: .public) error=\(String(describing: error), privacy: .public)")
        }
        continue
      }

      let minInterval: TimeInterval
      if emergency {
        minInterval = 0
      } else if inRampPhase {
        minInterval = self.config.rampMinSecondsBetweenChanges
      } else {
        minInterval = self.config.minSecondsBetweenChanges
      }

      if !emergency, let last = lastChangeTime[f],
         now.timeIntervalSince(last) < minInterval {
        log.debug(
          "fan.skip_min_interval fan=\(f, privacy: .public) elapsed=\(now.timeIntervalSince(last), privacy: .public) threshold=\(minInterval, privacy: .public)"
        )
        continue
      }

      let delta = targetRpm - prev
      if !emergency, !inRampPhase {
        if delta > 0 && delta < self.config.rampUpMinDelta {
          log.debug("fan.rpm_skip_up_small_delta fan=\(f, privacy: .public) delta=\(delta, privacy: .public)")
          continue
        }
        if delta < 0 && -delta < self.config.rampDownMinDelta {
          log.debug("fan.rpm_skip_down_small_delta fan=\(f, privacy: .public) delta=\(delta, privacy: .public)")
          continue
        }
      }

      if delta == 0 {
        log.debug("fan.rpm_skip_no_delta fan=\(f, privacy: .public) rpm=\(targetRpm, privacy: .public)")
        continue
      }

      log.notice(
        "fan.rpm_set fan=\(f, privacy: .public) state=\(self.state.rawValue, privacy: .public) previous_rpm=\(prev, privacy: .public) target_rpm=\(targetRpm, privacy: .public) delta=\(delta, privacy: .public) in_ramp=\(inRampPhase, privacy: .public) emergency=\(emergency, privacy: .public)"
      )
      do {
        try await smc.setRpm(fanIndex: f, rpm: targetRpm)
        lastAppliedRpm[f] = targetRpm
        lastChangeTime[f] = now
      } catch {
        log.error("fan.set_rpm_failed fan=\(f, privacy: .public) target_rpm=\(targetRpm, privacy: .public) error=\(String(describing: error), privacy: .public)")
      }
    }
  }

  private func activeSteadyTarget(inputs: FanInputs) -> Int {
    let maxSmoothTemp = max(smoothCpuTempC, smoothGpuTempC)
    let tempRpm = rpmForTemp(maxSmoothTemp, curve: self.config.curve)
    let floorRpm = activityFloorRpm(
      cpuPercent: smoothCpuPct,
      gpuPercent: smoothGpuPct,
      pressureFreePct: inputs.pressureFreePct,
      llmActive: true
    )
    log.debug(
      "fan.active_target_calc max_smooth_temp=\(maxSmoothTemp, privacy: .public) temp_rpm=\(tempRpm, privacy: .public) floor_rpm=\(floorRpm, privacy: .public)"
    )
    return max(tempRpm, floorRpm)
  }

  private func steadyCoolingTarget(inputs: FanInputs) -> Int {
    let maxSmoothTemp = max(smoothCpuTempC, smoothGpuTempC)
    let tempRpm = rpmForTemp(maxSmoothTemp, curve: self.config.curve)
    let floorRpm = activityFloorRpm(
      cpuPercent: smoothCpuPct,
      gpuPercent: smoothGpuPct,
      pressureFreePct: inputs.pressureFreePct,
      llmActive: false
    )
    log.debug(
      "fan.steady_target_calc max_smooth_temp=\(maxSmoothTemp, privacy: .public) temp_rpm=\(tempRpm, privacy: .public) floor_rpm=\(floorRpm, privacy: .public)"
    )
    return max(tempRpm, floorRpm)
  }

  private func enterActive(now: Date) {
    state = .active
    handedToAuto = false
    activeRampStartedAt = now
    coolingStartedAt = nil
    self.smc.setCurrentPriority(self.config.activePriority)
    log.debug("fan.state_entered_active now=\(now.timeIntervalSinceReferenceDate, privacy: .public)")
    for f in self.activeFanIndices {
      self.activeStartRpm[f] = self.lastAppliedRpm[f] ?? self.config.startupBaselineRpm
      log.debug(
        "fan.active_seed fan=\(f, privacy: .public) start_rpm=\(self.activeStartRpm[f] ?? self.config.startupBaselineRpm, privacy: .public)"
      )
      self.lastChangeTime.removeValue(forKey: f)
    }
    log.info("fan.state_changed from=idle to=active")
    logSink("fan state: idle -> active")
  }

  /// Enter the cooling state. Snapshots per-fan RPM so the hold window holds
  /// that value and the subsequent ramp starts from it.
  private func enterCooling(now: Date) {
    state = .cooling
    coolingStartedAt = now
    activeRampStartedAt = nil
    self.smc.setCurrentPriority(self.config.coolingPriority)
    log.debug("fan.state_entered_cooling now=\(now.timeIntervalSinceReferenceDate, privacy: .public)")
    for f in self.activeFanIndices {
      self.coolingStartRpm[f] = self.lastAppliedRpm[f] ?? self.config.startupBaselineRpm
      log.debug(
        "fan.cooling_seed fan=\(f, privacy: .public) hold_rpm=\(self.coolingStartRpm[f] ?? self.config.startupBaselineRpm, privacy: .public)"
      )
    }
    log.info("fan.state_changed from=active to=cooling")
    logSink("fan state: active -> cooling")
  }

  private func reenterActiveFromCooling(now: Date) {
    state = .active
    activeRampStartedAt = now
    coolingStartedAt = nil
    self.smc.setCurrentPriority(self.config.activePriority)
    log.debug("fan.state_reenter_active now=\(now.timeIntervalSinceReferenceDate, privacy: .public)")
    for f in self.activeFanIndices {
      self.activeStartRpm[f] = self.lastAppliedRpm[f] ?? self.config.startupBaselineRpm
      log.debug(
        "fan.reenter_seed fan=\(f, privacy: .public) start_rpm=\(self.activeStartRpm[f] ?? self.config.startupBaselineRpm, privacy: .public)"
      )
      self.lastChangeTime.removeValue(forKey: f)
    }
  }
}
