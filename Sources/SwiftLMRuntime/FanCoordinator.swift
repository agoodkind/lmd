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
  /// Seconds to ramp from current RPM to SMC max when LLM becomes active.
  public let activeRampDuration: TimeInterval
  /// Seconds to ramp down when leaving active toward the steady cooling target.
  public let coolingRampDownSeconds: TimeInterval
  /// Smoothed max(CPU, GPU) temp at or above this requests 10_000 RPM while active.
  public let activeFullBlastTempC: Double
  /// Minimum interval between writes while an active or cooling ramp is in progress.
  public let rampMinSecondsBetweenChanges: TimeInterval
  /// When SMC max RPM cannot be read, use this value for ramp ceilings.
  public let fallbackMaxRpm: Int

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
    activeRampDuration: TimeInterval = 7.5,
    coolingRampDownSeconds: TimeInterval = 60,
    activeFullBlastTempC: Double = 93,
    rampMinSecondsBetweenChanges: TimeInterval = 0.5,
    fallbackMaxRpm: Int = 9000
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
    self.coolingRampDownSeconds = coolingRampDownSeconds
    self.activeFullBlastTempC = activeFullBlastTempC
    self.rampMinSecondsBetweenChanges = rampMinSecondsBetweenChanges
    self.fallbackMaxRpm = fallbackMaxRpm
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

  private var smoothCpuPct: Double = 0
  private var smoothGpuPct: Double = 0
  private var smoothCpuTempC: Double = 0
  private var smoothGpuTempC: Double = 0

  private var lastAppliedRpm: [Int: Int] = [:]
  private var lastChangeTime: [Int: Date] = [:]

  private var smcMaxRpmByFan: [Int: Int] = [:]
  private var activeRampStartedAt: Date?
  private var activeStartRpm: [Int: Int] = [:]
  private var coolingRampStartedAt: Date?
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

  /// Take over fans. Stops `fancurveagent`, pins a safe baseline RPM.
  public func takeOver() {
    log.notice(
      "fan.coordinator_taking_over baseline_rpm=\(self.config.startupBaselineRpm, privacy: .public) fan_indices=\(self.config.fanIndices, privacy: .public)"
    )
    let uid = getuid()
    let bootoutResult = smc.runLaunchProcess(
      "/bin/launchctl",
      ["bootout", "gui/\(uid)/io.goodkind.fancurveagent"]
    )
    log.debug("fan.coordinator_fancurveagent_bootout status=\(bootoutResult, privacy: .public)")
    let pkillResult = smc.runLaunchProcess(
      "/usr/bin/pkill",
      ["-9", "-f", "fancurveagent"]
    )
    log.debug("fan.coordinator_fancurveagent_pkill status=\(pkillResult, privacy: .public)")
    Thread.sleep(forTimeInterval: 0.5)

    do {
      try smc.smcOpenIfNeededSync()
      smcMaxRpmByFan.removeAll()
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
          log.error(
            "fan.baseline_set_failed fan=\(f, privacy: .public) target=\(self.config.startupBaselineRpm, privacy: .public) error=\(String(describing: error), privacy: .public)"
          )
          throw error
        }
      }
      handedToAuto = true
    } catch {
      log.error(
        "fan.takeover_smc_failed error=\(String(describing: error), privacy: .public)"
      )
    }

    logSink("fan coordinator took over (baseline \(self.config.startupBaselineRpm) rpm)")
  }

  /// Hand fans back to auto and reload the launchd agent if present.
  public func release() {
    log.notice(
      "fan.coordinator_releasing fan_indices=\(self.config.fanIndices, privacy: .public)"
    )
    do {
      for f in self.config.fanIndices {
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
    let uid = getuid()
    let plist = NSString(string: "~/Library/LaunchAgents/io.goodkind.fancurveagent.plist")
      .expandingTildeInPath
    if FileManager.default.fileExists(atPath: plist) {
      log.debug("fan.release_launchctl_bootstrap uid=\(uid, privacy: .public) plist=\(plist, privacy: .public)")
      let bootstrapResult = smc.runLaunchProcess("/bin/launchctl", ["bootstrap", "gui/\(uid)", plist])
      log.debug("fan.release_launchctl_bootstrap_result result=\(bootstrapResult, privacy: .public)")
    }
    logSink("fan coordinator released, fans back to auto")
  }

  // MARK: - Tick

  /// Feed one sample of inputs into the coordinator.
  public func apply(_ inputs: FanInputs, now: Date = Date()) async throws {
    let previousState = self.state
    if self.config.fanIndices.isEmpty {
      log.error(
        "fan.apply_no_fans configured fan_indices=\(self.config.fanIndices, privacy: .public)"
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
        log.info("fan.state_changed from=idle to=active")
        enterActive(now: now)
      }
    case .active:
      if !llmActive {
        state = .cooling
        coolingStartedAt = now
        self.enterCoolingRamp(now: now)
        log.info("fan.state_changed from=active to=cooling")
        logSink("fan state: active -> cooling")
      }
    case .cooling:
      if llmActive {
        state = .active
        coolingStartedAt = nil
        reenterActiveFromCooling(now: now)
        log.info("fan.state_changed from=cooling to=active")
        logSink("fan state: cooling -> active")
      } else {
          let maxTemp = max(self.smoothCpuTempC, self.smoothGpuTempC)
        let elapsed = coolingStartedAt.map { now.timeIntervalSince($0) } ?? 0
          let tempOk = maxTemp <= self.config.coolOffTempC
          let timeUp = elapsed >= self.config.coolOffMaxSeconds
        if tempOk || timeUp {
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
            "fan.cooling_hold max_temp=\(maxTemp, privacy: .public) elapsed=\(elapsed, privacy: .public) temp_threshold=\(self.config.coolOffTempC, privacy: .public) timeout_seconds=\(self.config.coolOffMaxSeconds, privacy: .public)"
          )
        }
      }
    }

    log.debug("fan.apply_state after_transition=\(self.state.rawValue, privacy: .public) from=\(previousState.rawValue, privacy: .public)")

    if self.state == .idle {
      if !self.handedToAuto {
        for f in self.config.fanIndices {
          log.debug("fan.auto_set fan=\(f, privacy: .public)")
          do {
            try await smc.setAuto(fanIndex: f)
            log.info("fan.auto_set_success fan=\(f, privacy: .public)")
          } catch {
            log.error("fan.auto_set_failed fan=\(f, privacy: .public) error=\(String(describing: error), privacy: .public)")
            throw error
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

    let inCoolingRampWindow = self.state == .cooling
      && self.coolingRampStartedAt.map({ now.timeIntervalSince($0) < self.config.coolingRampDownSeconds }) == true

    let inRampPhase = inActiveRampWindow || inCoolingRampWindow
    log.debug(
      "fan.ramp_eval state=\(self.state.rawValue, privacy: .public) active_ramp=\(inActiveRampWindow, privacy: .public) cooling_ramp=\(inCoolingRampWindow, privacy: .public) in_ramp_phase=\(inRampPhase, privacy: .public)"
    )

    let steadyCooling = steadyCoolingTarget(inputs: inputs)
    log.debug("fan.steady_target steady=\(steadyCooling, privacy: .public)")

    for f in self.config.fanIndices {
      let targetRpm: Int
      if self.state == .active {
        if emergency {
          targetRpm = 10_000
        } else if hotEnoughForFullBlast {
          targetRpm = 10_000
        } else if let rampStart = activeRampStartedAt,
                  now.timeIntervalSince(rampStart) < self.config.activeRampDuration {
          let elapsed = now.timeIntervalSince(rampStart)
          let rampT = min(1, elapsed / self.config.activeRampDuration)
          let smcMax = smcMaxRpmByFan[f] ?? self.config.fallbackMaxRpm
          let start = self.activeStartRpm[f] ?? self.config.startupBaselineRpm
          targetRpm = lerpInt(start, smcMax, rampT)
        } else {
          targetRpm = smcMaxRpmByFan[f] ?? self.config.fallbackMaxRpm
        }
      } else {
      if let cr = self.coolingRampStartedAt,
           now.timeIntervalSince(cr) < self.config.coolingRampDownSeconds {
          let rampT = min(1, now.timeIntervalSince(cr) / self.config.coolingRampDownSeconds)
          let startRpm = coolingStartRpm[f] ?? steadyCooling
          targetRpm = lerpInt(startRpm, steadyCooling, rampT)
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
          throw error
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
        throw error
      }
    }
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
    coolingRampStartedAt = nil
    log.debug("fan.state_entered_active now=\(now.timeIntervalSinceReferenceDate, privacy: .public)")
    for f in self.config.fanIndices {
      self.activeStartRpm[f] = self.lastAppliedRpm[f] ?? self.config.startupBaselineRpm
      log.debug(
        "fan.active_seed fan=\(f, privacy: .public) start_rpm=\(self.activeStartRpm[f] ?? self.config.startupBaselineRpm, privacy: .public)"
      )
      self.lastChangeTime.removeValue(forKey: f)
    }
    log.info("fan.state_changed from=idle to=active")
    logSink("fan state: idle -> active")
  }

  private func enterCoolingRamp(now: Date) {
    coolingRampStartedAt = now
    activeRampStartedAt = nil
    log.debug("fan.state_entered_cooling now=\(now.timeIntervalSinceReferenceDate, privacy: .public)")
    for f in self.config.fanIndices {
      self.coolingStartRpm[f] = self.lastAppliedRpm[f] ?? self.config.startupBaselineRpm
      log.debug(
        "fan.cooling_seed fan=\(f, privacy: .public) start_rpm=\(self.coolingStartRpm[f] ?? self.config.startupBaselineRpm, privacy: .public)"
      )
    }
  }

  private func reenterActiveFromCooling(now: Date) {
    activeRampStartedAt = now
    coolingRampStartedAt = nil
    coolingStartedAt = nil
    log.debug("fan.state_reenter_active now=\(now.timeIntervalSinceReferenceDate, privacy: .public)")
    for f in self.config.fanIndices {
      self.activeStartRpm[f] = self.lastAppliedRpm[f] ?? self.config.startupBaselineRpm
      log.debug(
        "fan.reenter_seed fan=\(f, privacy: .public) start_rpm=\(self.activeStartRpm[f] ?? self.config.startupBaselineRpm, privacy: .public)"
      )
      self.lastChangeTime.removeValue(forKey: f)
    }
  }
}
