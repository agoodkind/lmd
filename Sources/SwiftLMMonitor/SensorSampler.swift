//
//  SensorSampler.swift
//  SwiftLMMonitor
//
//  Samples the host's macmon + battery + vm_stat + swap + loadavg once
//  per call and appends one JSONL record to a rolling data file.
//
//  Runs as an embedded Task inside `lmd-serve` (the broker). This used
//  to be a standalone daemon (`swiftmon`) but that was an extra moving
//  part that only existed because the broker did not exist yet. Now
//  that the broker runs 24/7 anyway, it owns the sampler too. One
//  fewer LaunchAgent. One fewer binary. Same data artifact on disk.
//
//  Data artifact per Rule 0 of the logging policy: samples go into
//  `memory.jsonl`. The sampler also emits a `monitor.sampled` event
//  through `os.Logger` per run so operators can see sampling activity
//  via `log stream --subsystem io.goodkind.lmd`.
//

import AppLogger
import Foundation

private let log = AppLogger.logger(category: "SensorSampler")

public final class SensorSampler: @unchecked Sendable {
  public struct Config {
    /// Directory under which `memory.jsonl` and `sensor.pid` live.
    public var baseDir: String
    /// Interval between samples. 15s matches the historical swiftmon default.
    public var intervalSeconds: Double
    /// macmon HTTP port. Reused if already bound.
    public var macmonPort: Int
    /// Absolute path to the `macmon` binary. Nil disables macmon.
    public var macmonBinary: String?

    public init(
      baseDir: String,
      intervalSeconds: Double = 15,
      macmonPort: Int = 8765,
      macmonBinary: String? = "/opt/homebrew/bin/macmon"
    ) {
      self.baseDir = baseDir
      self.intervalSeconds = intervalSeconds
      self.macmonPort = macmonPort
      self.macmonBinary = macmonBinary
    }
  }

  private let config: Config
  private var macmonProcess: Process?
  private let isoFmt: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime]
    return f
  }()

  public init(config: Config) {
    self.config = config
  }

  /// Start the background sampling loop. Safe to call once per process.
  public func start() {
    log.notice(
      "sampler.starting interval_s=\(self.config.intervalSeconds, privacy: .public) base_dir=\(self.config.baseDir, privacy: .public)"
    )
    startMacmonIfNeeded()
    Task.detached(priority: .utility) { [weak self] in
      await self?.loop()
    }
  }

  private func loop() async {
    while true {
      autoreleasepool { self.sampleOnce() }
      let ns = UInt64(config.intervalSeconds * 1_000_000_000)
      try? await Task.sleep(nanoseconds: ns)
    }
  }

  // MARK: - macmon lifecycle

  private func macmonIsResponding() -> Bool {
    guard let url = URL(string: "http://127.0.0.1:\(config.macmonPort)/json") else { return false }
    let sem = DispatchSemaphore(value: 0)
    var ok = false
    var req = URLRequest(url: url, timeoutInterval: 0.8)
    req.httpMethod = "GET"
    let t = URLSession.shared.dataTask(with: req) { data, _, _ in
      defer { sem.signal() }
      if let d = data, !d.isEmpty { ok = true }
    }
    t.resume()
    _ = sem.wait(timeout: .now() + 1.0)
    return ok
  }

  private func startMacmonIfNeeded() {
    guard let binary = config.macmonBinary else { return }
    if macmonIsResponding() {
      log.info("macmon.reusing port=\(self.config.macmonPort, privacy: .public)")
      return
    }
    let p = Process()
    p.launchPath = binary
    p.arguments = ["serve", "--port", "\(config.macmonPort)", "-i", "2000"]
    p.standardOutput = FileHandle(forWritingAtPath: "/dev/null")
    p.standardError = FileHandle(forWritingAtPath: "/dev/null")
    do {
      try p.run()
      macmonProcess = p
      Thread.sleep(forTimeInterval: 1.5)
      log.notice(
        "macmon.started pid=\(p.processIdentifier, privacy: .public) port=\(self.config.macmonPort, privacy: .public)"
      )
    } catch {
      log.error("macmon.start_failed error=\(String(describing: error), privacy: .public)")
    }
  }

  private func fetchMacmon() -> [String: Any]? {
    guard let url = URL(string: "http://127.0.0.1:\(config.macmonPort)/json") else { return nil }
    let sem = DispatchSemaphore(value: 0)
    var result: [String: Any]?
    var req = URLRequest(url: url, timeoutInterval: 1.5)
    req.httpMethod = "GET"
    let task = URLSession.shared.dataTask(with: req) { data, _, _ in
      defer { sem.signal() }
      guard let d = data,
            let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any]
      else { return }
      result = obj
    }
    task.resume()
    _ = sem.wait(timeout: .now() + 2)
    return result
  }

  // MARK: - Signed battery reader (ioreg-backed)

  private func readBatteryWattsSigned() -> Double? {
    let text = runCommandCaptureOut("/usr/sbin/ioreg", args: ["-rn", "AppleSmartBattery"])
    if text.isEmpty { return nil }
    var mA: Int64?
    var mV: Int64?
    for raw in text.split(separator: "\n") {
      let line = String(raw)
      if line.contains("\"InstantAmperage\""),
         let r = line.range(of: #"=\s*(\d+)"#, options: .regularExpression) {
        let s = String(line[r]).replacingOccurrences(of: "=", with: "").trimmingCharacters(in: .whitespaces)
        if let n = UInt64(s) { mA = Int64(bitPattern: n) }
      }
      if line.contains("\"Voltage\""), !line.contains("Pack"), !line.contains("Cell"),
         let r = line.range(of: #"=\s*(\d+)"#, options: .regularExpression) {
        let s = String(line[r]).replacingOccurrences(of: "=", with: "").trimmingCharacters(in: .whitespaces)
        mV = Int64(s)
      }
    }
    guard let a = mA, let v = mV else { return nil }
    return (Double(a) * Double(v)) / 1_000_000
  }

  // MARK: - Battery

  private func readBattery() -> (pct: Int, ac: String, source: String) {
    let text = runCommandCaptureOut("/usr/bin/pmset", args: ["-g", "batt"])
    if text.isEmpty { return (0, "unknown", "unknown") }
    var pct = 0
    var ac = "battery"
    var source = "unknown"
    let lines = text.split(separator: "\n").map(String.init)
    if let first = lines.first, let range = first.range(of: "'[^']+'", options: .regularExpression) {
      source = String(first[range]).trimmingCharacters(in: CharacterSet(charactersIn: "'"))
    }
    if let match = text.range(of: #"(\d+)%"#, options: .regularExpression) {
      let m = String(text[match]).trimmingCharacters(in: CharacterSet(charactersIn: "%"))
      pct = Int(m) ?? 0
    }
    let isCharging = text.range(of: #";\s*charging"#, options: .regularExpression) != nil
    if isCharging {
      ac = "charging"
    } else if text.contains("AC Power") || text.contains("AC attached") {
      ac = "ac_not_charging"
    }
    return (pct, ac, source)
  }

  // MARK: - One sample pass

  private func sampleOnce() {
    let ts = isoFmt.string(from: Date())

    let vmOut = runCommandCaptureOut("/usr/bin/vm_stat", args: [])
    func vmField(_ name: String) -> Int64 {
      for line in vmOut.split(separator: "\n") {
        if line.contains(name) {
          let nums = line.split(separator: ":").last.map(String.init) ?? ""
          let digits = nums.filter { $0.isNumber }
          return Int64(digits) ?? 0
        }
      }
      return 0
    }
    let pageouts = vmField("Pageouts")
    let pageins = vmField("Pageins")
    let comps = vmField("Compressions")
    let decomps = vmField("Decompressions")
    let pgCompressed = vmField("Pages stored in compressor")
    let pgFree = vmField("Pages free")
    let pgActive = vmField("Pages active")
    let pgInactive = vmField("Pages inactive")
    let pgWired = vmField("Pages wired down")

    let swapOut = runCommandCaptureOut("/usr/sbin/sysctl", args: ["-n", "vm.swapusage"])
    var swapUsed = "0", swapTotal = "0"
    let swapFields = swapOut.split(separator: " ").map(String.init)
    for (i, f) in swapFields.enumerated() {
      if f == "used" && i + 2 < swapFields.count { swapUsed = swapFields[i + 2] }
      if f == "total" && i + 2 < swapFields.count { swapTotal = swapFields[i + 2] }
    }

    let pressureOut = runCommandCaptureOut("/usr/bin/memory_pressure", args: [])
    var pressureFree = 0
    for line in pressureOut.split(separator: "\n") {
      if line.contains("System-wide memory free percentage") {
        let digits = line.filter { $0.isNumber }
        pressureFree = Int(digits) ?? 0
        break
      }
    }

    var swapFiles = 0
    if let contents = try? FileManager.default.contentsOfDirectory(atPath: "/private/var/vm") {
      swapFiles = contents.filter { $0.hasPrefix("swapfile") }.count
    }

    let loadOut = runCommandCaptureOut("/usr/sbin/sysctl", args: ["-n", "vm.loadavg"])
    let loadFields = loadOut.split(separator: " ").map(String.init)
    let load1 = loadFields.count >= 2 ? (Double(loadFields[1]) ?? 0) : 0

    let (battPct, acState, source) = readBattery()

    let mac = fetchMacmon()
    let cpuTemp = ((mac?["temp"] as? [String: Any])?["cpu_temp_avg"] as? Double) ?? 0
    let gpuTemp = ((mac?["temp"] as? [String: Any])?["gpu_temp_avg"] as? Double) ?? 0
    let cpuPct = ((mac?["cpu_usage_pct"] as? Double) ?? 0) * 100
    let gpuPct = ((mac?["gpu_usage"] as? [Any])?.last as? Double).map { $0 * 100 } ?? 0
    let cpuPower = (mac?["cpu_power"] as? Double) ?? 0
    let gpuPower = (mac?["gpu_power"] as? Double) ?? 0
    let sysPower = (mac?["sys_power"] as? Double) ?? 0
    let anePower = (mac?["ane_power"] as? Double) ?? 0
    let ramUsageGb: Double = ((mac?["memory"] as? [String: Any])?["ram_usage"] as? Double)
      .map { $0 / 1_073_741_824 } ?? 0

    let sample: [String: Any] = [
      "ts": ts,
      "source": "lmd-serve",
      "pageouts": pageouts,
      "pageins": pageins,
      "compressions": comps,
      "decompressions": decomps,
      "pages_compressed": pgCompressed,
      "pages_free": pgFree,
      "pages_active": pgActive,
      "pages_inactive": pgInactive,
      "pages_wired": pgWired,
      "swap_used": swapUsed,
      "swap_total": swapTotal,
      "pressure_free_pct": pressureFree,
      "swap_files": swapFiles,
      "load1": load1,
      "batt_pct": battPct,
      "ac_state": acState,
      "batt_watts_signed": readBatteryWattsSigned() ?? 0,
      "power_source": source,
      "cpu_temp_c": cpuTemp,
      "gpu_temp_c": gpuTemp,
      "cpu_pct": cpuPct,
      "gpu_pct": gpuPct,
      "cpu_power_w": cpuPower,
      "gpu_power_w": gpuPower,
      "ane_power_w": anePower,
      "sys_power_w": sysPower,
      "ram_used_gb": ramUsageGb,
    ]

    writeSample(sample)

    log.debug(
      "monitor.sampled cpu_c=\(cpuTemp, privacy: .public) gpu_c=\(gpuTemp, privacy: .public) batt_w=\(self.readBatteryWattsSigned() ?? 0, privacy: .public)"
    )
  }

  private func writeSample(_ sample: [String: Any]) {
    let outPath = "\(config.baseDir)/memory.jsonl"
    guard let data = try? JSONSerialization.data(withJSONObject: sample),
          let line = String(data: data, encoding: .utf8)
    else { return }
    let toWrite = line + "\n"
    if !FileManager.default.fileExists(atPath: outPath) {
      try? FileManager.default.createDirectory(
        atPath: (outPath as NSString).deletingLastPathComponent,
        withIntermediateDirectories: true
      )
      FileManager.default.createFile(atPath: outPath, contents: nil)
    }
    if let fh = FileHandle(forWritingAtPath: outPath) {
      fh.seekToEndOfFile()
      fh.write(toWrite.data(using: .utf8)!)
      try? fh.close()
    }
  }

  // MARK: - Shell helper

  private func runCommandCaptureOut(_ path: String, args: [String]) -> String {
    let p = Process()
    p.launchPath = path
    p.arguments = args
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = FileHandle(forWritingAtPath: "/dev/null")
    do {
      try p.run()
    } catch {
      return ""
    }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return String(data: data, encoding: .utf8) ?? ""
  }
}
