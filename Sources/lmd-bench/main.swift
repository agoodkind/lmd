// lmd-bench: MLX inference benchmark orchestrator.
// Spawns SwiftLM server per model, runs test prompts against its
// OpenAI-compatible endpoint, saves structured JSON results.
// No Python, no node, all Swift.

import AppLogger
import Foundation
import SwiftLMBackend
import SwiftLMMonitor
import SwiftLMRuntime

AppLogger.bootstrap(subsystem: "io.goodkind.lmd")
private let log = AppLogger.logger(category: "BenchRunner")

// Module name and one of its exported symbols clash. Shadow the library
// type under a local alias so the rest of this file can say `SwiftLMServer`.
private typealias LibSwiftLMServer = SwiftLMBackend.SwiftLMServer

// MARK: - Configuration
//
// Every path here honors the environment for operator overrides. The
// defaults point at the legacy stress-test dataset while the dataset
// still lives at that path. New runs should set `LMD_BENCH_BASE_DIR`
// to relocate.

let baseDir: String = {
  if let env = ProcessInfo.processInfo.environment["LMD_BENCH_BASE_DIR"], !env.isEmpty {
    return env
  }
  return "/Users/agoodkind/Sites/lm-review-stress-test/configs-battery"
}()
let resultsDir = "\(baseDir)/results"
let promptsDir = "\(baseDir)/prompts"
let logPath = "\(baseDir)/logs/lmd-bench.log"
let swiftLMLogPath = "\(baseDir)/logs/swiftlm.log"
let memoryPath = "\(baseDir)/memory.jsonl"
let swiftLMBinary: String = {
  if let env = ProcessInfo.processInfo.environment["LMD_SWIFTLM_BINARY"], !env.isEmpty {
    return env
  }
  let home = NSHomeDirectory()
  return "\(home)/Sites/SwiftLM/.build/release/SwiftLM"
}()
let serverPort: Int = 5413
let serverHost = "127.0.0.1"
let perTestTimeout: TimeInterval = 1800  // 30 min default, enough for 122B in RAM
let smcfanBinary: String = {
  if let env = ProcessInfo.processInfo.environment["LMD_SMCFAN_BINARY"], !env.isEmpty {
    return env
  }
  return "/Users/agoodkind/Sites/macos-smc-fan/Products/smcfan"
}()
let fancurveAgentPath = "/Applications/FanCurve.app/Contents/MacOS/io.goodkind.fancurveagent"
let configsRepo = "/Users/agoodkind/Sites/configs"
let repoMaxBytes = 300_000

// Models in order: small to large. Local filesystem paths to existing downloads.
// Each entry also carries a short display name used for result file paths.
let models: [(displayName: String, path: String, maxTokens: Int)] = [
    ("qwen3.5-4b-mlx",
     "/Users/agoodkind/.lmstudio/models/mlx-community/Qwen3.5-4B-MLX-4bit",
     8192),
    ("qwen3-coder-30b-a3b-instruct@4bit",
     "/Users/agoodkind/.lmstudio/models/mlx-community/Qwen3-Coder-30B-A3B-Instruct-4bit",
     8192),
    ("qwen3-coder-30b-a3b-instruct@8bit",
     "/Users/agoodkind/.lmstudio/models/mlx-community/Qwen3-Coder-30B-A3B-Instruct-8bit",
     8192),
    ("qwen3-coder-30b-a3b-instruct-dwq-lr9e8",
     "/Users/agoodkind/.lmstudio/models/mlx-community/Qwen3-Coder-30B-A3B-Instruct-8bit-DWQ-lr9e8",
     8192),
    ("qwen3.6-35b-a3b",
     "/Users/agoodkind/.lmstudio/models/mlx-community/Qwen3.6-35B-A3B-4bit",
     8192),
    ("microsoft_phi-4-reasoning-plus",
     "/Users/agoodkind/.lmstudio/models/lmstudio-community/Phi-4-reasoning-plus-MLX-4bit",
     4096),
    ("qwen_qwen3-coder-next",
     "/Users/agoodkind/.lmstudio/models/lmstudio-community/Qwen3-Coder-Next-MLX-6bit",
     8192),
    ("qwen3.5-122b-a10b-text-mlx",
     "/Users/agoodkind/.lmstudio/models/nightmedia/Qwen3.5-122B-A10B-Text-mxfp4-mlx",
     8192),
]

let tests: [String] = [
    "review-general", "review-security", "review-networking",
    "review-discrepancies", "review-docs-drift",
    "chat-explain", "chat-troubleshoot",
    "chat-ipv6-rfc", "chat-bgp-ibgp", "chat-ospf",
    "chat-zero-downtime", "chat-high-throughput", "chat-topology",
    "chat-opnsense-api", "chat-wireguard", "chat-frr",
    "chat-firewall-rules", "chat-load-balancing",
    "chat-multi-wan", "chat-npt-nat", "chat-dhcpv6-pd",
]

// MARK: - Logging
//
// All swiftbench events route through `log` (file-scope `os.Logger`
// declared at the top of this file). The hand-rolled `Logger` class
// that mirrored stderr and a log file is gone; operators tail via
// `log stream --subsystem io.goodkind.lmd --info` instead.
//
// The legacy `logPath` constant above is retained only so we know
// which file to stop writing to; nothing in this file creates or
// opens it anymore.

// MARK: - Fan controller (thin shim over SwiftLMRuntime.FanCoordinator)
//
// The real state machine, curve interpolation, EMA smoothing, hysteresis,
// and shell invocation live in the library class. This wrapper preserves
// the legacy singleton call surface (`FanController.shared.start/apply/stop`)
// so existing call sites keep working. Configuration knobs are read from
// the same global constants the legacy class used.

final class FanController {
    static let shared = FanController()
    private let coordinator: FanCoordinator

    private init() {
        let cfg = FanCoordinatorConfig(smcfanBinary: smcfanBinary)
        self.coordinator = FanCoordinator(
            config: cfg,
            log: { message in log.info("\(message, privacy: .public)") }
        )
    }

    func start() { coordinator.takeOver() }
    func stop() { coordinator.release() }

    func apply(
        cpuTempC: Double, gpuTempC: Double,
        cpuPct: Double = 0, gpuPct: Double = 0,
        pressureFree: Int = 100, llmLoaded: Bool = false
    ) {
        coordinator.apply(
            FanInputs(
                cpuTempC: cpuTempC, gpuTempC: gpuTempC,
                cpuPercent: cpuPct, gpuPercent: gpuPct,
                pressureFreePct: pressureFree, llmLoaded: llmLoaded
            )
        )
    }
}

// MARK: - Memory / system monitor (runs in background, pauses current server on low battery)

final class MemoryMonitor {
    static let shared = MemoryMonitor()

    let outPath = memoryPath
    let intervalSeconds: Double = 15
    let macmonPort: Int = 8765
    let lowBatteryPct: Int = 30
    let resumeBatteryPct: Int = 75

    private var macmonProcess: Process?
    private weak var currentServer: SwiftLMServer?
    private let lock = NSLock()
    /// HTTP client to the macmon daemon. Owned by MemoryMonitor so the
    /// per-sample snapshot comes from one place.
    private let macmonClient = MacmonClient()
    private var paused: Bool = false
    private var stopRequested: Bool = false
    // Hoist long-lived objects so we don't churn them each sample.
    private let isoFmt: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
    private let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 2
        c.timeoutIntervalForResource = 2
        c.httpMaximumConnectionsPerHost = 1
        return URLSession(configuration: c)
    }()

    private init() {
        try? FileManager.default.createDirectory(
            atPath: (outPath as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true
        )
    }

    func setCurrentServer(_ server: SwiftLMServer?) {
        lock.lock()
        self.currentServer = server
        // When server changes, reset pause state (new process won't be stopped)
        self.paused = false
        lock.unlock()
    }

    func start() {
        startMacmon()
        DispatchQueue.global(qos: .utility).async { [weak self] in
            self?.runLoop()
        }
    }

    func stop() {
        lock.lock()
        stopRequested = true
        lock.unlock()
        if let p = macmonProcess, p.isRunning {
            p.terminate()
        }
    }

    private func startMacmon() {
        let p = Process()
        p.launchPath = "/opt/homebrew/bin/macmon"
        p.arguments = ["serve", "--port", "\(macmonPort)", "-i", "2000"]
        // Discard output so the pipe buffer never fills up over a long run.
        p.standardOutput = FileHandle(forWritingAtPath: "/dev/null")
        p.standardError = FileHandle(forWritingAtPath: "/dev/null")
        do {
            try p.run()
            self.macmonProcess = p
            Thread.sleep(forTimeInterval: 1.5)
            log.notice("macmon.started pid=\(p.processIdentifier, privacy: .public) port=\(self.macmonPort, privacy: .public)")
        } catch {
            log.error("macmon.start_failed error=\(String(describing: error), privacy: .public)")
        }
    }

    private func runLoop() {
        while true {
            lock.lock()
            let stop = stopRequested
            lock.unlock()
            if stop { return }

            // Autoreleasepool ensures per-sample ObjC temporaries (Process, Pipe,
            // NSData, etc.) are released promptly instead of waiting for the
            // outer runloop drain that never arrives on this utility queue.
            autoreleasepool {
                sampleOnce()
            }
            Thread.sleep(forTimeInterval: intervalSeconds)
        }
    }

    private func fetchMacmon() -> [String: Any]? {
        guard let url = URL(string: "http://127.0.0.1:\(macmonPort)/json") else { return nil }
        let sem = DispatchSemaphore(value: 0)
        var result: [String: Any]?
        var req = URLRequest(url: url, timeoutInterval: 1.5)
        req.httpMethod = "GET"
        let task = session.dataTask(with: req) { data, _, _ in
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
        // "discharging" contains "charging" as a substring, so match the
        // specific "; charging" token with a regex instead.
        let isCharging = text.range(of: #";\s*charging"#, options: .regularExpression) != nil
        if isCharging {
            ac = "charging"
        } else if text.contains("AC Power") || text.contains("AC attached") {
            ac = "ac_not_charging"
        }
        return (pct, ac, source)
    }

    private func sampleOnce() {
        let ts = isoFmt.string(from: Date())

        // Sensor readers all now live in the SwiftLMMonitor library. The
        // MemoryMonitor just composes them and adds the SwiftLMServer PID
        // awareness plus SIGSTOP / SIGCONT battery watchdog.
        let vm = VMStat.read()
        let swap = SwapUsage.read()
        let pressureFree = MemoryPressure.freePercent()
        let swapFiles = SwapFiles.count()
        let load1 = LoadAverage.oneMinute()
        let batt = Battery.read()
        let battWattsSigned = Battery.signedWatts() ?? 0

        let pageouts = vm.pageouts
        let pageins = vm.pageins
        let comps = vm.compressions
        let decomps = vm.decompressions
        let pgCompressed = vm.pagesCompressed
        let pgFree = vm.pagesFree
        let pgActive = vm.pagesActive
        let pgInactive = vm.pagesInactive
        let pgWired = vm.pagesWired
        let swapUsed = swap.used
        let swapTotal = swap.total
        let battPct = batt.percent
        let acState = batt.acState
        let source = batt.source

        let macSnap = macmonClient.fetch()
        let cpuTemp = macSnap.cpuTempC
        let gpuTemp = macSnap.gpuTempC
        let cpuPct = macSnap.cpuPercent
        let gpuPct = macSnap.gpuPercent

        let llmLoaded: Bool = {
            lock.lock()
            defer { lock.unlock() }
            if let p = currentServer?.process, p.isRunning { return true }
            return false
        }()
        if cpuTemp > 0 || gpuTemp > 0 {
            FanController.shared.apply(
                cpuTempC: cpuTemp, gpuTempC: gpuTemp,
                cpuPct: cpuPct, gpuPct: gpuPct,
                pressureFree: pressureFree,
                llmLoaded: llmLoaded
            )
        }
        let cpuPower = macSnap.cpuPowerW
        let gpuPower = macSnap.gpuPowerW
        let sysPower = macSnap.systemPowerW
        let anePower = macSnap.anePowerW
        let ramUsageGb = macSnap.ramUsedGB
        _ = battWattsSigned  // sampled for parity with swiftmon; not in the bench JSONL schema yet

        // Pause / resume decision
        lock.lock()
        let server = currentServer
        let wasPaused = paused
        lock.unlock()

        var pauseAction = "none"
        if let srv = server, let proc = srv.process {
            let pid = proc.processIdentifier
            if !wasPaused && battPct <= lowBatteryPct {
                kill(pid, SIGSTOP)
                lock.lock(); paused = true; lock.unlock()
                pauseAction = "paused_low_battery_\(battPct)pct"
                log.notice("monitor.paused_on_battery battery_pct=\(battPct, privacy: .public)")
            } else if wasPaused && battPct >= resumeBatteryPct && acState == "charging" {
                kill(pid, SIGCONT)
                lock.lock(); paused = false; lock.unlock()
                pauseAction = "resumed_battery_\(battPct)pct"
                log.notice("monitor.resumed_on_battery battery_pct=\(battPct, privacy: .public)")
            }
        }

        let pausedNow = (lock.lock(), paused, lock.unlock()).1
        let pidStr = server?.process?.processIdentifier.description ?? ""

        let sample: [String: Any] = [
            "ts": ts,
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
            "power_source": source,
            "target_pid": pidStr,
            "paused": pausedNow ? 1 : 0,
            "pause_action": pauseAction,
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

        if let data = try? JSONSerialization.data(withJSONObject: sample),
           let line = String(data: data, encoding: .utf8) {
            let toWrite = line + "\n"
            if !FileManager.default.fileExists(atPath: outPath) {
                FileManager.default.createFile(atPath: outPath, contents: nil)
            }
            if let fh = FileHandle(forWritingAtPath: outPath) {
                fh.seekToEndOfFile()
                fh.write(toWrite.data(using: .utf8)!)
                try? fh.close()
            }
        }
    }

    private func runCommandCaptureOut(_ path: String, args: [String]) -> String {
        let p = Process()
        p.launchPath = path
        p.arguments = args
        let outPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = FileHandle(forWritingAtPath: "/dev/null")
        do { try p.run() } catch { return "" }
        // Drain stdout while process runs so we never block on a full pipe buffer.
        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        try? outPipe.fileHandleForReading.close()
        return String(data: data, encoding: .utf8) ?? ""
    }
}

// MARK: - Path helpers

func sanitize(_ s: String) -> String {
    // Match bash version: replace / with _ then any non-alphanum/_/./- with _.
    var out = s.replacingOccurrences(of: "/", with: "_")
    let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_.-")
    out = String(out.map { allowed.contains($0) ? $0 : "_" })
    return out
}

func baseName(_ s: String) -> String {
    (s as NSString).lastPathComponent
}

func ensureDir(_ path: String) {
    try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
}

// MARK: - SwiftLM server lifecycle
//
// Thin wrapper around ``SwiftLMBackend.SwiftLMServer`` (the library class).
// Preserves the existing call surface (`startWithCtxSize`, `stop`,
// `waitReady(timeout:)`, `process` accessor) so the rest of swiftbench does
// not change. Future work: migrate call sites to the library type directly
// and delete this wrapper.

final class SwiftLMServer {
    let model: String
    let thinking: Bool
    var ctxSize: Int?
    private var backend: SwiftLMBackend.SwiftLMServer?

    init(model: String, thinking: Bool = false) {
        self.model = model
        self.thinking = thinking
        self.ctxSize = nil
    }

    /// Mirrors the legacy entry point used by the main phase loop.
    func startWithCtxSize(_ size: Int?) throws {
        self.ctxSize = size
        try start()
    }

    func start() throws {
        let b = SwiftLMBackend.SwiftLMServer(
            model: model,
            thinking: thinking,
            contextSize: ctxSize,
            config: SwiftLMServerConfig(
                binaryPath: swiftLMBinary,
                host: serverHost,
                port: serverPort,
                logFilePath: swiftLMLogPath,
                readyTimeout: 300
            ),
            log: { message in log.info("\(message, privacy: .public)") }
        )
        try b.start()
        self.backend = b
    }

    /// `process` is read by the MemoryMonitor to detect "LLM loaded". We
    /// surface it from the backend so existing readers keep working.
    var process: Process? { backend?.process }

    func waitReady(timeout: TimeInterval = 300) -> Bool {
        // The library takes the timeout via config at construction time,
        // so we can't change it per-call. The main phase always passes the
        // The main phase always uses the default 300, and reasoning-eval passes 600 via the caller.
        // Rebuild the library server if a bigger timeout is requested.
        if timeout > (backend?.config.readyTimeout ?? 0),
           let current = backend {
            current.stop()
            backend = nil
            // Re-construct with the larger timeout.
            let b = SwiftLMBackend.SwiftLMServer(
                model: model,
                thinking: thinking,
                contextSize: ctxSize,
                config: SwiftLMServerConfig(
                    binaryPath: swiftLMBinary,
                    host: serverHost,
                    port: serverPort,
                    logFilePath: swiftLMLogPath,
                    readyTimeout: timeout
                ),
                log: { message in log.info("\(message, privacy: .public)") }
            )
            do {
                try b.start()
            } catch {
                log.error("server.restart_failed error=\(String(describing: error), privacy: .public)")
                return false
            }
            self.backend = b
        }
        return backend?.waitReady() ?? false
    }

    func stop() {
        backend?.stop()
        backend = nil
    }
}

// MARK: - Repo dump (infra-priority files first)

func buildRepoDump(repo: String, maxBytes: Int) -> String {
    let priorityExt: Set<String> = [".conf", ".j2", ".yml", ".yaml", ".tmpl", ".service", ".in"]
    let codeExt: Set<String> = [".go", ".py", ".sh", ".rb", ".js", ".ts"]
    let skipDirs: Set<String> = ["node_modules", ".git", "dist", "build", "vendor", "target", "keepalived-src"]

    var total = 0
    var chunks: [String] = []

    func walk(wanted: Set<String>) {
        let fm = FileManager.default
        guard let e = fm.enumerator(atPath: repo) else { return }
        while let sub = e.nextObject() as? String {
            let full = (repo as NSString).appendingPathComponent(sub)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: full, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                if skipDirs.contains((sub as NSString).lastPathComponent) {
                    e.skipDescendants()
                }
                continue
            }
            let ext = "." + ((sub as NSString).pathExtension)
            guard wanted.contains(ext) else { continue }
            guard let data = fm.contents(atPath: full),
                  let text = String(data: data, encoding: .utf8) else { continue }
            let header = "\n\n// FILE: \(sub)\n"
            let piece = header + text
            if total + piece.count > maxBytes {
                let remain = maxBytes - total - header.count - 20
                if remain > 0 {
                    let trimmed = header + String(text.prefix(remain)) + "\n// [truncated]"
                    chunks.append(trimmed)
                    total = maxBytes
                }
                return
            }
            chunks.append(piece)
            total += piece.count
            if total >= maxBytes { return }
        }
    }

    walk(wanted: priorityExt)
    if total < maxBytes { walk(wanted: codeExt) }
    return chunks.joined()
}

// MARK: - HTTP chat call

struct ChatResult: Encodable {
    let start_ts: Int
    let end_ts: Int
    let elapsed_seconds: Int
    let http_code: Int
    let raw_response: String?
    let response: [String: AnyCodable]?
}

struct AnyCodable: Encodable {
    let value: Any
    init(_ v: Any) { value = v }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch value {
        case let v as String: try c.encode(v)
        case let v as Int: try c.encode(v)
        case let v as Double: try c.encode(v)
        case let v as Bool: try c.encode(v)
        case let v as [Any]: try c.encode(v.map { AnyCodable($0) })
        case let v as [String: Any]: try c.encode(v.mapValues { AnyCodable($0) })
        default:
            if let n = value as? NSNumber { try c.encode(n.doubleValue) }
            else { try c.encodeNil() }
        }
    }
}

func runChat(model: String, systemPrompt: String, userContent: String, maxTokens: Int) -> ChatResult {
    let start = Int(Date().timeIntervalSince1970)

    var userText = userContent
    if userText.count > repoMaxBytes {
        userText = String(userText.prefix(repoMaxBytes)) + "\n[TRUNCATED]"
    }

    let payload: [String: Any] = [
        "model": model,
        "messages": [
            ["role": "system", "content": systemPrompt],
            ["role": "user",   "content": userText],
        ],
        "temperature": 0.1,
        "max_tokens": maxTokens,
    ]

    let url = URL(string: "http://\(serverHost):\(serverPort)/v1/chat/completions")!
    var req = URLRequest(url: url)
    req.httpMethod = "POST"
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    req.timeoutInterval = perTestTimeout
    req.httpBody = try? JSONSerialization.data(withJSONObject: payload)

    let sem = DispatchSemaphore(value: 0)
    var resultData: Data?
    var httpCode = -1

    URLSession.shared.dataTask(with: req) { data, resp, err in
        if let r = resp as? HTTPURLResponse { httpCode = r.statusCode }
        resultData = data
        sem.signal()
    }.resume()

    _ = sem.wait(timeout: .now() + perTestTimeout + 10)
    let end = Int(Date().timeIntervalSince1970)

    var rawText: String? = nil
    var parsedResp: [String: AnyCodable]? = nil
    if let d = resultData {
        if let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
            parsedResp = obj.mapValues { AnyCodable($0) }
        } else {
            rawText = String(data: d, encoding: .utf8)
        }
    }

    return ChatResult(
        start_ts: start, end_ts: end,
        elapsed_seconds: end - start,
        http_code: httpCode,
        raw_response: rawText,
        response: parsedResp
    )
}

// MARK: - Skip-if-already-done

func isComplete(_ path: String) -> Bool {
    guard FileManager.default.fileExists(atPath: path),
          let data = FileManager.default.contents(atPath: path),
          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        return false
    }
    return obj["response"] != nil && !(obj["response"] is NSNull)
}

// MARK: - Main loop

func writeResult(_ r: ChatResult, to path: String) {
    let enc = JSONEncoder()
    enc.outputFormatting = [.prettyPrinted, .sortedKeys]
    if let d = try? enc.encode(r) {
        try? d.write(to: URL(fileURLWithPath: path))
    }
}

func runModel(displayName: String, path: String, maxTokens: Int) {
    log.notice("model.phase_start model=\(displayName, privacy: .public)")
    let safe = sanitize(displayName)
    let outDir = "\(resultsDir)/\(safe)_"
    ensureDir(outDir)

    // Fast exit if every test already parsed successfully.
    let pending = tests.filter { t in
        !isComplete("\(outDir)/\(t).json")
    }
    if pending.isEmpty {
        log.notice("model.skipped reason=all_done model=\(displayName, privacy: .public)")
        return
    }

    let server = SwiftLMServer(model: path)
    do {
        try server.start()
    } catch {
        log.error("server.start_failed model=\(displayName, privacy: .public) error=\(String(describing: error), privacy: .public)")
        return
    }
    MemoryMonitor.shared.setCurrentServer(server)
    defer {
        MemoryMonitor.shared.setCurrentServer(nil)
        server.stop()
    }

    guard server.waitReady() else {
        log.error("server.never_ready model=\(displayName, privacy: .public)")
        return
    }

    // Warmup: one tiny request to trigger MLX JIT, kernel compile, and KV cache alloc
    // before the real 80K-token prefills hit. Saves 5-30s on the first real request.
    log.info("server.warmup_start model=\(displayName, privacy: .public)")
    let warmupStart = Date()
    _ = runChat(model: path, systemPrompt: "You are helpful.", userContent: "Reply with just: ok", maxTokens: 8)
    log.info("server.warmup_done model=\(displayName, privacy: .public) elapsed_s=\(Int(Date().timeIntervalSince(warmupStart)), privacy: .public)")

    log.notice("server.ready model=\(displayName, privacy: .public) pending=\(pending.count, privacy: .public)")

    for testType in pending {
        let outFile = "\(outDir)/\(testType).json"
        let sysPromptPath = "\(promptsDir)/\(testType).txt"
        guard let sysPrompt = try? String(contentsOfFile: sysPromptPath) else {
            log.error("prompt.missing path=\(sysPromptPath, privacy: .public)")
            continue
        }
        let userContent = buildRepoDump(repo: configsRepo, maxBytes: repoMaxBytes)
        if userContent.isEmpty {
            log.info("cell.skipped reason=empty_content model=\(displayName, privacy: .public) test=\(testType, privacy: .public)")
            continue
        }
        log.notice("cell.running model=\(displayName, privacy: .public) test=\(testType, privacy: .public) bytes=\(userContent.count, privacy: .public)")
        let r = runChat(model: path, systemPrompt: sysPrompt, userContent: userContent, maxTokens: maxTokens)
        writeResult(r, to: outFile)
        log.notice("cell.completed model=\(displayName, privacy: .public) test=\(testType, privacy: .public) elapsed_s=\(r.elapsed_seconds, privacy: .public) http=\(r.http_code, privacy: .public)")
    }
    log.notice("model.phase_done model=\(displayName, privacy: .public)")
}

// MARK: - Signal handling for clean shutdown

signal(SIGINT, SIG_IGN)
signal(SIGTERM, SIG_IGN)
let sigSrc1 = DispatchSource.makeSignalSource(signal: SIGINT)
let sigSrc2 = DispatchSource.makeSignalSource(signal: SIGTERM)
sigSrc1.setEventHandler {
    log.notice("signal.received name=SIGINT action=shutdown")
    FanController.shared.stop()
    MemoryMonitor.shared.stop()
    exit(130)
}
sigSrc2.setEventHandler {
    log.notice("signal.received name=SIGTERM action=shutdown")
    FanController.shared.stop()
    MemoryMonitor.shared.stop()
    exit(143)
}
sigSrc1.resume()
sigSrc2.resume()

// MARK: - Entry

ensureDir(resultsDir)
ensureDir(promptsDir)

log.notice("bench.starting models=\(models.count, privacy: .public) tests=\(tests.count, privacy: .public) total=\(models.count * tests.count, privacy: .public)")

// Take over fan control so we keep the machine quiet under light load
FanController.shared.start()

// Start integrated memory/system monitor (which will drive the fan curve)
MemoryMonitor.shared.start()

for m in models {
    runModel(displayName: m.displayName, path: m.path, maxTokens: m.maxTokens)
}

log.notice("bench.main_phase_done")

// MARK: - Reasoning-eval phase
// For personal chat-driver evaluation on configs.
// Different profile: thinking enabled, bigger max_tokens, chat-only prompts.

let reasoningResultsDir = "\(baseDir)/reasoning-eval"
let reasoningChatTests: [String] = [
    "chat-explain", "chat-troubleshoot",
    "chat-ipv6-rfc", "chat-bgp-ibgp", "chat-ospf",
    "chat-zero-downtime", "chat-high-throughput", "chat-topology",
    "chat-opnsense-api", "chat-wireguard", "chat-frr",
    "chat-firewall-rules", "chat-load-balancing",
    "chat-multi-wan", "chat-npt-nat", "chat-dhcpv6-pd",
]

struct ReasoningModel {
    let displayName: String
    let path: String
    let maxTokens: Int
    let maxInputBytes: Int
    let ctxSize: Int?
}

let reasoningModels: [ReasoningModel] = [
    ReasoningModel(
        displayName: "qwen3.6-35b-a3b",
        path: "/Users/agoodkind/.lmstudio/models/mlx-community/Qwen3.6-35B-A3B-4bit",
        maxTokens: 16384,
        maxInputBytes: 300_000,
        ctxSize: 204800
    ),
    ReasoningModel(
        displayName: "microsoft_phi-4-reasoning-plus",
        path: "/Users/agoodkind/.lmstudio/models/lmstudio-community/Phi-4-reasoning-plus-MLX-4bit",
        maxTokens: 16384,
        maxInputBytes: 100_000,
        ctxSize: nil
    ),
]

func runReasoningModel(_ m: ReasoningModel) {
    log.notice("reasoning.phase_start model=\(m.displayName, privacy: .public)")
    let outDir = "\(reasoningResultsDir)/\(sanitize(m.displayName))_"
    ensureDir(outDir)

    let pending = reasoningChatTests.filter { t in
        !isComplete("\(outDir)/\(t).json")
    }
    if pending.isEmpty {
        log.notice("reasoning.skipped reason=all_done model=\(m.displayName, privacy: .public)")
        return
    }

    let server = SwiftLMServer(model: m.path, thinking: true)
    do {
        try server.startWithCtxSize(m.ctxSize)
    } catch {
        log.error("reasoning.server_start_failed model=\(m.displayName, privacy: .public) error=\(String(describing: error), privacy: .public)")
        return
    }
    MemoryMonitor.shared.setCurrentServer(server)
    defer {
        MemoryMonitor.shared.setCurrentServer(nil)
        server.stop()
    }

    guard server.waitReady(timeout: 600) else {
        log.error("reasoning.server_never_ready model=\(m.displayName, privacy: .public)")
        return
    }

    log.info("reasoning.warmup_start model=\(m.displayName, privacy: .public)")
    let warmupStart = Date()
    _ = runChat(model: m.path, systemPrompt: "You are helpful.", userContent: "Reply with just: ok", maxTokens: 16)
    log.info("reasoning.warmup_done model=\(m.displayName, privacy: .public) elapsed_s=\(Int(Date().timeIntervalSince(warmupStart)), privacy: .public)")

    for testType in pending {
        let outFile = "\(outDir)/\(testType).json"
        let sysPromptPath = "\(promptsDir)/\(testType).txt"
        guard let sysPrompt = try? String(contentsOfFile: sysPromptPath) else {
            log.error("prompt.missing path=\(sysPromptPath, privacy: .public)")
            continue
        }
        var userContent = buildRepoDump(repo: configsRepo, maxBytes: m.maxInputBytes)
        if userContent.isEmpty { continue }
        if userContent.count > m.maxInputBytes {
            userContent = String(userContent.prefix(m.maxInputBytes))
        }
        log.notice("reasoning.cell_running model=\(m.displayName, privacy: .public) test=\(testType, privacy: .public) bytes=\(userContent.count, privacy: .public)")
        let r = runChat(model: m.path, systemPrompt: sysPrompt, userContent: userContent, maxTokens: m.maxTokens)
        writeResult(r, to: outFile)
        log.notice("reasoning.cell_completed model=\(m.displayName, privacy: .public) test=\(testType, privacy: .public) elapsed_s=\(r.elapsed_seconds, privacy: .public) http=\(r.http_code, privacy: .public)")
    }
    log.notice("reasoning.phase_done model=\(m.displayName, privacy: .public)")
}

log.notice("bench.reasoning_phase_starting")
ensureDir(reasoningResultsDir)
for rm in reasoningModels {
    runReasoningModel(rm)
}

log.notice("bench.complete")
MemoryMonitor.shared.stop()
FanController.shared.stop()
