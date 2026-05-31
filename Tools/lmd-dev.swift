//
//  lmd-dev.swift
//  lmd-dev
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-05-10.
//  Copyright © 2026, all rights reserved.
//

import Darwin
import Foundation

let productBinaries = ["lmd", "lmd-serve"]
let compatibilityCommandLinks = [
  "lmd-tui": "lmd",
  "lmd-bench": "lmd",
  "lmd-qa": "lmd",
]
let defaultBundleIdentifierPrefix = "io.goodkind.lmd"
let defaultVideoModel = "mlx-community/Qwen2.5-VL-32B-Instruct-4bit"
let supportedVideoExtensions: Set<String> = [
  "avi",
  "m4v",
  "mkv",
  "mov",
  "mp4",
  "mpeg",
  "mpg",
  "webm",
]

enum ToolError: Error, CustomStringConvertible {
  case usage(String)
  case failure(String)

  var description: String {
    switch self {
    case .usage(let message):
      return message
    case .failure(let message):
      return message
    }
  }
}

struct CommandResult {
  let status: Int32
  let output: String
}

struct Environment {
  let values: [String: String]

  init() {
    values = ProcessInfo.processInfo.environment
  }

  func value(_ name: String, default defaultValue: String) -> String {
    values[name] ?? defaultValue
  }

  func required(_ name: String) throws -> String {
    guard let value = values[name], !value.isEmpty else {
      throw ToolError.failure("\(name) is not set")
    }
    return value
  }
}

struct HTTPResult {
  let statusCode: Int
  let data: Data
}

struct BuildCacheTool {
  let name: String
  let executable: String
}

struct SmokeConfiguration {
  let binaryDirectory: URL
  let host: String
  let port: Int
  let useRunningDaemon: Bool
  let videoModel: String
  let videoSampleFile: URL?
  let videoTimeoutSeconds: TimeInterval
  let videoMaxTokens: Int

  var baseURL: URL {
    URL(string: "http://\(host):\(port)")!
  }

  init(environment: [String: String], repoRoot: URL) throws {
    let binaryDirectoryPath = environment["LMD_BINARY_DIR"] ?? "Products/Build/Release"
    binaryDirectory = URL(fileURLWithPath: binaryDirectoryPath, relativeTo: repoRoot)
      .standardizedFileURL

    host = environment["LMD_HOST"] ?? "localhost"
    guard Self.isAllowedHost(host) else {
      throw ToolError.failure("LMD_HOST must be localhost or [::1], got \(host)")
    }

    useRunningDaemon = environment["LMD_SMOKE_USE_RUNNING_DAEMON"] == "1"
    if let portValue = environment["LMD_PORT"], !portValue.isEmpty {
      guard let parsedPort = Int(portValue), (1...65_535).contains(parsedPort) else {
        throw ToolError.failure("LMD_PORT must be an integer from 1 through 65535, got \(portValue)")
      }
      port = parsedPort
    } else if useRunningDaemon {
      port = 5400
    } else {
      port = Int.random(in: 15_000..<16_000)
    }

    videoModel = environment["LMD_VIDEO_MODEL"] ?? defaultVideoModel
    if let samplePath = environment["LMD_VIDEO_SAMPLE_FILE"], !samplePath.isEmpty {
      videoSampleFile = URL(fileURLWithPath: samplePath).standardizedFileURL
    } else {
      videoSampleFile = nil
    }

    videoTimeoutSeconds = try Self.parsePositiveDouble(
      environment["LMD_VIDEO_TIMEOUT_SECONDS"],
      defaultValue: 1_800,
      variableName: "LMD_VIDEO_TIMEOUT_SECONDS"
    )
    videoMaxTokens = try Self.parsePositiveInt(
      environment["LMD_VIDEO_MAX_TOKENS"],
      defaultValue: 96,
      variableName: "LMD_VIDEO_MAX_TOKENS"
    )
  }

  private static func isAllowedHost(_ host: String) -> Bool {
    host == "localhost" || host == "[::1]"
  }

  private static func parsePositiveDouble(
    _ rawValue: String?,
    defaultValue: Double,
    variableName: String
  ) throws -> Double {
    guard let rawValue, !rawValue.isEmpty else {
      return defaultValue
    }
    guard let value = Double(rawValue), value > 0, value.isFinite else {
      throw ToolError.failure("\(variableName) must be greater than 0, got \(rawValue)")
    }
    return value
  }

  private static func parsePositiveInt(
    _ rawValue: String?,
    defaultValue: Int,
    variableName: String
  ) throws -> Int {
    guard let rawValue, !rawValue.isEmpty else {
      return defaultValue
    }
    guard let value = Int(rawValue), value > 0 else {
      throw ToolError.failure("\(variableName) must be an integer greater than 0, got \(rawValue)")
    }
    return value
  }
}

struct ModelsResponse: Decodable {
  let object: String
  let data: [ModelEntry]

  struct ModelEntry: Decodable {}
}

struct LoadedModelsResponse: Decodable {
  let models: [LoadedModel]
  let allocatedGB: Double

  enum CodingKeys: String, CodingKey {
    case models
    case allocatedGB = "allocated_gb"
  }

  struct LoadedModel: Decodable {}
}

struct ChatCompletionResponse: Decodable {
  let choices: [Choice]

  struct Choice: Decodable {
    let message: Message
  }

  struct Message: Decodable {
    let content: MessageContent
  }
}

enum MessageContent: Decodable {
  case text(String)
  case parts([ContentPart])
  case empty

  init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    if let text = try? container.decode(String.self) {
      self = .text(text)
      return
    }
    if let parts = try? container.decode([ContentPart].self) {
      self = .parts(parts)
      return
    }
    self = .empty
  }

  var isNonEmpty: Bool {
    switch self {
    case .text(let text):
      return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    case .parts(let parts):
      return parts.contains { part in
        guard let text = part.text else {
          return false
        }
        return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      }
    case .empty:
      return false
    }
  }

  struct ContentPart: Decodable {
    let text: String?
  }
}

struct VideoChatRequest: Encodable {
  let model: String
  let messages: [Message]
  let maxTokens: Int
  let temperature: Double

  enum CodingKeys: String, CodingKey {
    case model
    case messages
    case maxTokens = "max_tokens"
    case temperature
  }

  struct Message: Encodable {
    let role: String
    let content: [ContentPart]
  }

  struct ContentPart: Encodable {
    let type: String
    let text: String?
    let videoURL: VideoURL?

    enum CodingKeys: String, CodingKey {
      case type
      case text
      case videoURL = "video_url"
    }

    static func text(_ text: String) -> Self {
      Self(type: "text", text: text, videoURL: nil)
    }

    static func video(url: URL) -> Self {
      Self(
        type: "video_url",
        text: nil,
        videoURL: VideoURL(url: url.absoluteString, fps: 1, maxFrames: 16)
      )
    }
  }

  struct VideoURL: Encodable {
    let url: String
    let fps: Double
    let maxFrames: Int

    enum CodingKeys: String, CodingKey {
      case url
      case fps
      case maxFrames = "max_frames"
    }
  }
}

final class DevTool {
  private let fileManager = FileManager.default
  private let environment = Environment()
  private let repoRoot: URL

  init() throws {
    repoRoot = try Self.findRepoRoot()
  }

  func run(arguments: [String]) async throws {
    guard let command = arguments.first else {
      try help()
      return
    }

    let rest = Array(arguments.dropFirst())
    switch command {
    case "help", "--help", "-h":
      try help()
    case "toolchain":
      try toolchain()
    case "build":
      try build(configuration: configuration(from: rest.first, defaultValue: "Release"))
    case "debug":
      try build(configuration: "Debug")
    case "test":
      try test()
    case "snapshot-update":
      try snapshotUpdate()
    case "clean":
      try clean()
    case "install":
      try install(configuration: configuration(from: rest.first, defaultValue: "Release"))
    case "uninstall":
      try uninstall()
    case "start-serve":
      try startServe()
    case "stop-serve":
      try stopServe()
    case "restart-serve":
      try restartServe()
    case "run-serve":
      try runBuiltBinary("lmd-serve")
    case "run-tui":
      try runBuiltCommand(["tui"])
    case "run-bench":
      try runBuiltCommand(["bench"])
    case "smoke":
      try buildProduct("lmd-serve", configuration: "Release")
      try await smoke(requireVideo: false)
    case "video-smoke":
      try buildProduct("lmd-serve", configuration: "Release")
      try await smoke(requireVideo: true)
    case "tui-qa":
      try tuiQA(target: rest.first)
    case "log-audit":
      try logAudit()
    case "log-smoke":
      try logSmoke()
    case "notary-setup":
      try notarySetup()
    case "preflight":
      try preflight()
    case "sign":
      try build(configuration: "Release")
      try signLocal(targets: rest)
    case "notarize":
      try build(configuration: "Release")
      try notarizeLocal()
    case "dist":
      try build(configuration: "Release")
      try signLocal(targets: [])
      _ = try notarize(mode: .local)
      try writeLine("[dist] artifacts: \(productsDirectory().path)")
    case "ci-import-cert":
      try ciImportCertificate()
    case "ci-sign":
      try signCI()
    case "ci-notarize":
      _ = try notarize(mode: .ci)
    case "release-tag":
      try releaseTag()
    case "push-tag":
      try pushTag()
    case "github-release":
      try githubRelease()
    case "cleanup-keychain":
      try cleanupKeychain()
    case "lint":
      try lint()
    case "format":
      try format()
    default:
      throw ToolError.usage("unknown command: \(command)")
    }
  }

  private static func findRepoRoot() throws -> URL {
    var current = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
      .standardizedFileURL

    while true {
      let project = current.appendingPathComponent("Project.swift").path
      let agents = current.appendingPathComponent("AGENTS.md").path
      if FileManager.default.fileExists(atPath: project),
        FileManager.default.fileExists(atPath: agents)
      {
        return current
      }

      let parent = current.deletingLastPathComponent()
      if parent.path == current.path {
        throw ToolError.failure("could not find repo root from \(FileManager.default.currentDirectoryPath)")
      }
      current = parent
    }
  }

  private func help() throws {
    try writeLine(
      """
      lmd-dev commands:
        preflight               verify Swift, Tuist, and the Metal toolchain;
                                download the Metal toolchain if missing
        build [Release|Debug]   SwiftPM build of every product binary, plus
                                xcodebuild build of just the MLX shader bundle
        debug                   build every product binary in Debug
        install [Release|Debug] build and copy to PREFIX/bin (default Release)
        test                    run Tuist test for LMDTests
        smoke                   build and run the Swift HTTP smoke test
        video-smoke             build and require real video acceptance via LMD_VIDEO_SAMPLE_FILE
        log-audit               enforce first-party logging rules
        log-smoke               exercise CLI logging and check redactions
        sign                    build and codesign product CLIs and shader bundle
        notarize                build, sign, and notarize the staged release
        dist                    build, sign, notarize, and write the artifact path
      """
    )
  }

  private func toolchain() throws {
    try runPassthrough("swift", ["--version"])
    _ = try? runPassthrough("xcodebuild", ["-version"])
    try runPassthrough(tuistExecutable(), ["version"])
  }

  private func configuration(from rawValue: String?, defaultValue: String) throws -> String {
    guard let rawValue else {
      return defaultValue
    }
    let lowercased = rawValue.lowercased()
    if lowercased == "release" {
      return "Release"
    }
    if lowercased == "debug" {
      return "Debug"
    }
    throw ToolError.usage("configuration must be Release or Debug")
  }

  /// Build every product binary plus the MLX Metal shader library.
  ///
  /// The build is split across two systems because neither alone produces a
  /// usable artifact on macOS:
  ///
  /// - SwiftPM (`swift build`) links `swift-nio` with the resilient layout
  ///   the Swift runtime expects, but cannot compile `.metal` shaders.
  /// - xcodebuild (via Tuist) compiles `.metal` into `default.metallib`, but
  ///   the resulting executables link `swift-nio`'s `ManagedAtomic<Bool>`
  ///   without the required type metadata. The first socket allocation
  ///   inside `BaseSocketChannel.init(...)` then crashes with
  ///   `EXC_BAD_ACCESS` in `swift_allocObject`.
  ///
  /// Upstream context:
  /// - https://github.com/ml-explore/mlx-swift/issues/345 (metallib packaging)
  /// - https://github.com/ml-explore/mlx-swift/issues/36 (SwiftPM cannot compile Metal)
  /// - https://github.com/vapor/vapor/issues/3369 (Tuist/swift-nio linkage bug)
  ///
  /// `stageBuildArtifacts` collects outputs from both systems into a single
  /// staging directory under `Products/Build/<configuration>/`. `install`
  /// reads exclusively from that staging directory and does not need to know
  /// about either build system.
  private func build(configuration: String) throws {
    try buildSwiftPackage(configuration: configuration)
    try buildMetallib(configuration: configuration)
    try stageBuildArtifacts(products: productBinaries, configuration: configuration)
  }

  /// Build a single product binary plus the metallib. Used by smoke targets
  /// that only need `lmd-serve`. Same hybrid rationale as `build`.
  private func buildProduct(_ product: String, configuration: String) throws {
    try buildSwiftPackageProduct(product, configuration: configuration)
    try buildMetallib(configuration: configuration)
    try stageBuildArtifacts(products: [product], configuration: configuration)
  }

  /// SwiftPM build of every product. Outputs land at
  /// `.build/<configuration>/<product>` (configuration is lower-cased per
  /// SwiftPM's convention: `debug`, `release`).
  private func buildSwiftPackage(configuration: String) throws {
    try runPassthrough(
      "swift",
      ["build", "-c", swiftPackageConfiguration(configuration)],
      environment: try buildEnvironment()
    )
  }

  /// SwiftPM build of one product. Faster than `buildSwiftPackage` when the
  /// caller only needs a single binary.
  private func buildSwiftPackageProduct(_ product: String, configuration: String) throws {
    try runPassthrough(
      "swift",
      ["build", "-c", swiftPackageConfiguration(configuration), "--product", product],
      environment: try buildEnvironment()
    )
  }

  /// xcodebuild build of the `mlx-swift_Cmlx` target only. Produces
  /// `Derived/Build/Products/<configuration>/mlx-swift_Cmlx.bundle` and
  /// nothing else. The target has no dependencies and contains no Swift, so
  /// it sidesteps the NIO type-metadata crash that affects Xcode-built Swift
  /// executables in this project. SwiftPM cannot compile `.metal` files, so
  /// this xcodebuild call exists for that one capability.
  private func buildMetallib(configuration: String) throws {
    try ensureMetalToolchain()
    try tuistInstallAndGenerate()
    try runPassthrough(
      "xcodebuild",
      try xcodeBuildArguments(
        project: mlxSwiftProjectPath(),
        scheme: "mlx-swift_Cmlx",
        configuration: configuration
      ),
      environment: try buildEnvironment()
    )
  }

  /// Verify that the Metal shader compiler is on disk. Apple distributes it
  /// through an on-demand cryptex mount, and a fresh Xcode install ships
  /// without it. When `xcrun --find metal` fails we run
  /// `xcodebuild -downloadComponent MetalToolchain` once and re-check.
  private func ensureMetalToolchain() throws {
    if hasMetalCompiler() {
      return
    }
    try writeLine("[preflight] Metal toolchain missing; running xcodebuild -downloadComponent MetalToolchain")
    try runPassthrough("xcodebuild", ["-downloadComponent", "MetalToolchain"])
    guard hasMetalCompiler() else {
      throw ToolError.failure(
        "preflight: Metal toolchain still missing after download; check Xcode install"
      )
    }
  }

  private func hasMetalCompiler() -> Bool {
    let result = try? run(
      "xcrun",
      ["--find", "metal"],
      currentDirectory: nil,
      environment: nil,
      captureOutput: true
    )
    return (result?.status ?? 1) == 0
  }

  /// One-shot environment check. Confirms Swift, Tuist, and the Metal
  /// shader compiler are all reachable, and downloads the Metal toolchain
  /// if absent. Safe to run repeatedly.
  private func preflight() throws {
    try runPassthrough("swift", ["--version"])
    try runPassthrough(tuistExecutable(), ["version"])
    try ensureMetalToolchain()
    if let path = try? captureMetalPath() {
      try writeLine("[preflight] metal: \(path)")
    }
    try writeLine("[preflight] ok")
  }

  private func captureMetalPath() throws -> String {
    let result = try run(
      "xcrun",
      ["--find", "metal"],
      currentDirectory: nil,
      environment: nil,
      captureOutput: true
    )
    return result.output.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  /// Path to the mlx-swift Xcode project that Tuist generates under
  /// `Tuist/.build/tuist-derived/Projects/`. The path is stable across
  /// Tuist versions in use today.
  private func mlxSwiftProjectPath() -> URL {
    repoRoot.appendingPathComponent(
      "Tuist/.build/tuist-derived/Projects/mlx-swift/mlx-swift.xcodeproj"
    )
  }

  /// Copy SwiftPM binaries and the Xcode-built metallib into the single
  /// staging directory at `Products/Build/<configuration>/`.
  ///
  /// Both halves of the hybrid build write here so `install` can read from
  /// one location. Throws if SwiftPM did not produce an expected binary.
  /// The failure message names the missing path so the operator can run
  /// `swift build` standalone to surface the underlying compile error.
  private func stageBuildArtifacts(products: [String], configuration: String) throws {
    let staging = buildDirectory(configuration: configuration)
    try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
    let swiftBuild = swiftPackageBuildDirectory(configuration: configuration)
    for product in products {
      let source = swiftBuild.appendingPathComponent(product)
      guard fileManager.isExecutableFile(atPath: source.path) else {
        throw ToolError.failure("SwiftPM did not produce \(source.path)")
      }
      try copyReplacingItem(at: source, to: staging.appendingPathComponent(product))
      try writeLine("  staged \(product)")
    }
    try stageCompatibilityLinks(in: staging)
    try stageRuntimeResources(for: configuration)
  }

  private func test() throws {
    try tuistInstallAndGenerate()
    var env = ProcessInfo.processInfo.environment
    env["LMD_BINARY_DIR"] = releaseBuildDirectory().path
    try runPassthrough(
      tuistExecutable(),
      [
        "test",
        "LMDTests",
        "--configuration",
        "Debug",
        "--platform",
        "macos",
        "--no-selective-testing",
        "--inspect-mode",
        "off",
      ],
      environment: env
    )
  }

  private func snapshotUpdate() throws {
    try tuistInstallAndGenerate()
    var env = ProcessInfo.processInfo.environment
    env["SNAPSHOT_UPDATE"] = "1"
    try runPassthrough(
      tuistExecutable(),
      [
        "test",
        "LMDTests",
        "--configuration",
        "Debug",
        "--platform",
        "macos",
        "--no-selective-testing",
        "--inspect-mode",
        "off",
        "--test-targets",
        "SwiftLMTUITests",
      ],
      environment: env
    )
  }

  private func clean() throws {
    for path in [
      ".build",
      "Derived",
      "LMD.xcodeproj",
      "LMD.xcworkspace",
      "lmd.xcodeproj",
      "lmd.xcworkspace",
      "Tuist/.build",
      "Products/Build",
    ] {
      try removeIfExists(repoRoot.appendingPathComponent(path))
    }
  }

  private func install(configuration: String) throws {
    try build(configuration: configuration)
    let sourceDirectory = buildDirectory(configuration: configuration)
    let binDirectory = prefixDirectory().appendingPathComponent("bin")
    try fileManager.createDirectory(at: binDirectory, withIntermediateDirectories: true)

    for binary in productBinaries {
      let source = sourceDirectory.appendingPathComponent(binary)
      let destination = binDirectory.appendingPathComponent(binary)
      try copyReplacingItem(at: source, to: destination)
      try writeLine("  installed \(destination.path)")
    }
    try stageCompatibilityLinks(in: binDirectory)

    try copyRuntimeResources(from: sourceDirectory, to: binDirectory)

    let agentDirectory = homeDirectory().appendingPathComponent("Library/LaunchAgents")
    try fileManager.createDirectory(at: agentDirectory, withIntermediateDirectories: true)
    let templateURL = repoRoot.appendingPathComponent("deploy/io.goodkind.lmd.serve.plist.example")
    let template = try String(contentsOf: templateURL, encoding: .utf8)
    let rendered = template.replacingOccurrences(
      of: "{{LMD_SERVE_PATH}}",
      with: binDirectory.appendingPathComponent("lmd-serve").path
    )
    try rendered.write(to: agentPlistURL(), atomically: true, encoding: .utf8)
    try writeLine("  wrote \(agentPlistURL().path)")
    try startServe()
  }

  private func uninstall() throws {
    try? stopServe()
    try removeIfExists(agentPlistURL())

    let binDirectory = prefixDirectory().appendingPathComponent("bin")
    for binary in productBinaries + Array(compatibilityCommandLinks.keys) {
      let path = binDirectory.appendingPathComponent(binary)
      if fileManager.fileExists(atPath: path.path) {
        try fileManager.removeItem(at: path)
        try writeLine("  removed \(path.path)")
      }
    }
    for resourceName in ["mlx.metallib", "default.metallib", "mlx-swift_Cmlx.bundle"] {
      let path = binDirectory.appendingPathComponent(resourceName)
      if fileManager.fileExists(atPath: path.path) {
        try fileManager.removeItem(at: path)
        try writeLine("  removed \(path.path)")
      }
    }
  }

  private func startServe() throws {
    guard fileManager.fileExists(atPath: agentPlistURL().path) else {
      throw ToolError.failure("no agent plist at \(agentPlistURL().path); run 'make install' first")
    }

    let domain = "gui/\(getuid())"
    let serviceTarget = "\(domain)/io.goodkind.lmd.serve"

    // Bootout first if loaded so launchd re-reads the plist and picks up
    // the binary we just copied. The bootout call returns before launchd
    // finishes removing the service label from the domain, so a tight
    // bootstrap right after races and gets EIO. Poll until the label is
    // gone before bootstrapping.
    if isServiceLoaded(serviceTarget) {
      _ = try? runPassthrough("launchctl", ["bootout", serviceTarget])
      waitForServiceUnload(serviceTarget, timeoutSeconds: 5)
    }

    try runPassthrough("launchctl", ["bootstrap", domain, agentPlistURL().path])
    try writeLine("  bootstrapped io.goodkind.lmd.serve")
  }

  /// Probe whether a launchd service is loaded. Uses `launchctl print` and
  /// swallows its stderr so the not-loaded case ("Bad request") does not
  /// leak to the user's terminal.
  private func isServiceLoaded(_ serviceTarget: String) -> Bool {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
    process.arguments = ["print", serviceTarget]
    let sink = Pipe()
    process.standardOutput = sink
    process.standardError = sink
    do {
      try process.run()
    } catch {
      return false
    }
    process.waitUntilExit()
    sink.fileHandleForReading.readDataToEndOfFile()
    return process.terminationStatus == 0
  }

  private func waitForServiceUnload(_ serviceTarget: String, timeoutSeconds: Int) {
    let deadline = Date().addingTimeInterval(TimeInterval(timeoutSeconds))
    while Date() < deadline {
      if !isServiceLoaded(serviceTarget) {
        return
      }
      Thread.sleep(forTimeInterval: 0.1)
    }
  }

  private func stopServe() throws {
    let service = "gui/\(getuid())/io.goodkind.lmd.serve"
    do {
      try runPassthrough("launchctl", ["bootout", service])
      try writeLine("  booted out io.goodkind.lmd.serve")
    } catch {
      try writeLine("  io.goodkind.lmd.serve was not loaded")
    }
  }

  private func restartServe() throws {
    let service = "gui/\(getuid())/io.goodkind.lmd.serve"
    do {
      try runPassthrough("launchctl", ["kickstart", "-k", service])
      try writeLine("  kickstarted io.goodkind.lmd.serve")
    } catch {
      try writeLine("  io.goodkind.lmd.serve not registered; run 'make install'")
    }
  }

  private func runBuiltBinary(_ name: String) throws {
    try build(configuration: "Release")
    try runPassthrough(releaseBuildDirectory().appendingPathComponent(name).path, [])
  }

  private func runBuiltCommand(_ arguments: [String]) throws {
    try build(configuration: "Release")
    try runPassthrough(releaseBuildDirectory().appendingPathComponent("lmd").path, arguments)
  }

  private func smoke(requireVideo: Bool) async throws {
    let configuration = try SmokeConfiguration(environment: environment.values, repoRoot: repoRoot)
    if requireVideo, configuration.videoSampleFile == nil {
      throw ToolError.failure("video-smoke requires LMD_VIDEO_SAMPLE_FILE")
    }
    let runner = SmokeRunner(configuration: configuration)
    try await runner.run()
  }

  private func tuiQA(target: String?) throws {
    _ = try runCaptured("tmux", ["-V"])
    var env = ProcessInfo.processInfo.environment
    env["LMD_BINARY_DIR"] = releaseBuildDirectory().path
    var args = ["qa"]
    if let target {
      args.append(target)
    }
    try runPassthrough(releaseBuildDirectory().appendingPathComponent("lmd").path, args, environment: env)
  }

  private func logAudit() throws {
    try writeLine("[log-audit] scanning for forbidden output calls...")
    let swiftFiles = try sourceSwiftFiles(excludingPathComponent: "AppLogger")
    let outputPattern = try NSRegularExpression(pattern: "(^|[^A-Za-z_])(print|NSLog|debugPrint|dump)\\(")
    var failed = false

    for file in swiftFiles {
      let content = try String(contentsOf: file, encoding: .utf8)
      let range = NSRange(content.startIndex..<content.endIndex, in: content)
      if outputPattern.firstMatch(in: content, range: range) != nil {
        try writeLine("[log-audit] output call violation: \(relativePath(file))")
        failed = true
      }
    }
    if failed {
      throw ToolError.failure("[log-audit] FAILED: replace with log.<level>(...) or FileHandle.standardOutput.write")
    }
    try writeLine("[log-audit]   output calls: OK")

    try writeLine("[log-audit] scanning for direct Logger(subsystem:) construction...")
    for file in swiftFiles {
      let content = try String(contentsOf: file, encoding: .utf8)
      if content.contains("Logger(subsystem:") {
        try writeLine("[log-audit] Logger construction violation: \(relativePath(file))")
        failed = true
      }
    }
    if failed {
      throw ToolError.failure("[log-audit] FAILED: use AppLogger.logger(category:) instead")
    }
    try writeLine("[log-audit]   Logger construction: OK")

    try writeLine("[log-audit] scanning for swift-log direct use...")
    for file in swiftFiles {
      let content = try String(contentsOf: file, encoding: .utf8)
      if content.components(separatedBy: .newlines).contains("import Logging") {
        try writeLine("[log-audit] swift-log import violation: \(relativePath(file))")
        failed = true
      }
    }
    if failed {
      throw ToolError.failure("[log-audit] FAILED: swift-log must route through AppLogger/SwiftLogBridge")
    }
    try writeLine("[log-audit]   swift-log direct use: OK")
    try writeLine("[log-audit] PASSED")
  }

  private func logSmoke() throws {
    let captureFile = temporaryFileURL(prefix: "log-smoke", suffix: ".ndjson")
    let startDate = Date()
    try writeLine("[log-smoke] START \(logDateFormatter().string(from: startDate))")

    _ = try? runPassthrough(releaseBuildDirectory().appendingPathComponent("lmd").path, ["--help"])
    _ = try? runPassthrough(releaseBuildDirectory().appendingPathComponent("lmd").path, ["ls"])
    Thread.sleep(forTimeInterval: 1)

    let result = try runCaptured(
      "/usr/bin/log",
      [
        "show",
        "--predicate",
        "subsystem == 'io.goodkind.lmd'",
        "--start",
        logDateFormatter().string(from: startDate),
        "--style",
        "ndjson",
        "--info",
      ]
    )
    try result.output.write(to: captureFile, atomically: true, encoding: .utf8)
    try writeLine("[log-smoke] capture size: \(result.output.split(separator: "\n").count) lines at \(captureFile.path)")

    if result.output.contains("<private>") {
      throw ToolError.failure("[log-smoke] FAILED: <private> redactions detected. Capture at \(captureFile.path)")
    }

    try removeIfExists(captureFile)
    try writeLine("[log-smoke] PASSED")
  }

  private func notarySetup() throws {
    let signing = try localSigningConfig()
    let appleID = signing["APPLE_ID"] ?? prompt("Apple ID email: ")
    guard !appleID.isEmpty else {
      throw ToolError.failure("notary-setup: Apple ID is required")
    }

    try writeLine("[notary-setup] storing credentials in keychain profile: \(try signing.required("NOTARY_PROFILE"))")
    try writeLine("[notary-setup] team: \(try signing.required("DEVELOPMENT_TEAM"))")
    try runPassthrough(
      "xcrun",
      [
        "notarytool",
        "store-credentials",
        try signing.required("NOTARY_PROFILE"),
        "--apple-id",
        appleID,
        "--team-id",
        try signing.required("DEVELOPMENT_TEAM"),
      ]
    )
  }

  private func signLocal(targets: [String]) throws {
    let signing = try localSigningConfig()
    let selectedTargets = targets.isEmpty ? productBinaries : targets
    try signTargets(
      selectedTargets,
      identity: try signing.required("CODE_SIGN_IDENTITY"),
      bundleIdentifierPrefix: try signing.required("BUNDLE_ID_PREFIX")
    )
  }

  private func signCI() throws {
    try signTargets(
      productBinaries,
      identity: try environment.required("APPLE_CODE_SIGN_IDENTITY"),
      bundleIdentifierPrefix: defaultBundleIdentifierPrefix
    )
  }

  private enum NotarizeMode {
    case local
    case ci
  }

  private func notarizeLocal() throws {
    try signLocal(targets: [])
    _ = try notarize(mode: .local)
  }

  @discardableResult
  private func notarize(mode: NotarizeMode) throws -> URL {
    let scratch = try temporaryDirectory(prefix: "lmd-notarize")
    defer {
      try? fileManager.removeItem(at: scratch)
    }

    try fileManager.createDirectory(at: productsDirectory(), withIntermediateDirectories: true)
    try stageSignedBinaries(into: scratch)

    let zipPath = productsDirectory().appendingPathComponent("lmd-\(artifactStamp()).zip")
    try runPassthrough("/usr/bin/ditto", ["-c", "-k", "--keepParent", ".", zipPath.path], currentDirectory: scratch)

    switch mode {
    case .local:
      let signing = try localSigningConfig()
      try runPassthrough(
        "xcrun",
        ["notarytool", "submit", zipPath.path, "--keychain-profile", try signing.required("NOTARY_PROFILE"), "--wait"]
      )
    case .ci:
      let keyIdentifier = try environment.required("APPLE_API_KEY_ID")
      let keyPath = scratch.appendingPathComponent("AuthKey_\(keyIdentifier).p8")
      try decodeBase64Environment("APPLE_API_KEY_P8_BASE64").write(to: keyPath, options: .atomic)
      try runPassthrough(
        "xcrun",
        [
          "notarytool",
          "submit",
          zipPath.path,
          "--key",
          keyPath.path,
          "--key-id",
          keyIdentifier,
          "--issuer",
          try environment.required("APPLE_API_ISSUER_ID"),
          "--wait",
        ]
      )
      try appendGitHubOutput(name: "artifact", value: zipPath.path)
    }

    try writeLine("[notarize] bare binaries cannot be stapled; first-launch checks online.")
    return zipPath
  }

  private func ciImportCertificate() throws {
    let certificateData = try decodeBase64Environment("APPLE_DEVELOPER_ID_P12_BASE64")
    let certificatePassword = try environment.required("APPLE_DEVELOPER_ID_P12_PASSWORD")
    let keychainPassword = environment.values["KEYCHAIN_PASSWORD"] ?? UUID().uuidString  // gitleaks:allow
    let runnerTemp = environment.value("RUNNER_TEMP", default: NSTemporaryDirectory())
    let keychainPath = URL(fileURLWithPath: runnerTemp).appendingPathComponent("lmd-build.keychain-db")
    let scratch = try temporaryDirectory(prefix: "lmd-cert")
    defer {
      try? fileManager.removeItem(at: scratch)
    }

    let certificatePath = scratch.appendingPathComponent("cert.p12")
    try certificateData.write(to: certificatePath, options: .atomic)

    try runPassthrough("security", ["create-keychain", "-p", keychainPassword, keychainPath.path])
    try runPassthrough("security", ["set-keychain-settings", "-lut", "7200", keychainPath.path])
    try runPassthrough("security", ["unlock-keychain", "-p", keychainPassword, keychainPath.path])
    try runPassthrough("security", ["list-keychains", "-d", "user", "-s", keychainPath.path] + currentUserKeychains())
    try runPassthrough(
      "security",
      [
        "import",
        certificatePath.path,
        "-k",
        keychainPath.path,
        "-P",
        certificatePassword,
        "-T",
        "/usr/bin/codesign",
        "-T",
        "/usr/bin/security",
      ]
    )
    try runPassthrough(
      "security",
      [
        "set-key-partition-list",
        "-S",
        "apple-tool:,apple:,codesign:",
        "-s",
        "-k",
        keychainPassword,
        keychainPath.path,
      ]
    )
    try appendGitHubEnvironment(name: "CI_KEYCHAIN_PATH", value: keychainPath.path)
  }

  private func releaseTag() throws {
    let runNumber = Int(environment.value("GITHUB_RUN_NUMBER", default: "0")) ?? 0
    let sha = try runCaptured("git", ["-C", repoRoot.path, "rev-parse", "--short", "HEAD"]).output
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let tag = "\(releaseTagFormatter().string(from: Date()))-\(String(runNumber, radix: 16))-\(sha)"
    try appendGitHubOutput(name: "tag", value: tag)
    try writeLine("Release tag: \(tag)")
  }

  private func pushTag() throws {
    let tag = try environment.required("TAG")
    try runPassthrough("git", ["-C", repoRoot.path, "config", "user.name", "github-actions[bot]"])
    try runPassthrough("git", ["-C", repoRoot.path, "config", "user.email", "github-actions[bot]@users.noreply.github.com"])
    try runPassthrough("git", ["-C", repoRoot.path, "tag", tag])
    try runPassthrough("git", ["-C", repoRoot.path, "push", "origin", tag])
  }

  private func githubRelease() throws {
    try runPassthrough(
      "gh",
      [
        "release",
        "create",
        try environment.required("TAG"),
        try environment.required("ARTIFACT"),
        "--title",
        try environment.required("TAG"),
        "--notes",
        "Signed + notarized build from \(environment.value("GITHUB_SHA", default: "unknown")). Bare CLI binaries cannot be stapled; first-launch Gatekeeper checks hit the network.",
      ]
    )
  }

  private func cleanupKeychain() throws {
    guard let keychainPath = environment.values["CI_KEYCHAIN_PATH"], !keychainPath.isEmpty else {
      return
    }
    guard fileManager.fileExists(atPath: keychainPath) else {
      return
    }
    _ = try? runPassthrough("security", ["delete-keychain", keychainPath])
  }

  private func lint() throws {
    do {
      try runPassthrough("swift-format", ["lint", "--recursive", "Sources", "Tests", "Tools"])
    } catch {
      try writeLine("swift-format not installed or failed, skipping")
    }
    do {
      try runPassthrough("swiftlint", ["--quiet"])
    } catch {
      try writeLine("swiftlint not installed or failed, skipping")
    }
  }

  private func format() throws {
    do {
      try runPassthrough("swift-format", ["format", "--in-place", "--recursive", "Sources", "Tests", "Tools"])
    } catch {
      try writeLine("swift-format not installed or failed, skipping")
    }
  }

  private func tuistInstallAndGenerate() throws {
    try runPassthrough(tuistExecutable(), ["install"])
    try runPassthrough(tuistExecutable(), ["generate", "--no-open", "--cache-profile", "none"])
  }

  private func tuistExecutable() -> String {
    environment.value("TUIST", default: "tuist")
  }

  /// Compose `xcodebuild` arguments for either a workspace+scheme build or
  /// a project+scheme build. `project` is nil for the workspace form.
  private func xcodeBuildArguments(
    project: URL? = nil,
    scheme: String,
    configuration: String
  ) throws -> [String] {
    var arguments: [String] = []
    if let project {
      arguments.append(contentsOf: ["-project", project.path])
    } else {
      arguments.append(contentsOf: ["-workspace", "lmd.xcworkspace"])
    }
    arguments.append(contentsOf: [
      "-scheme",
      scheme,
      "-configuration",
      configuration,
      "-destination",
      "platform=macOS,arch=arm64",
      "-derivedDataPath",
      repoRoot.appendingPathComponent("Derived").path,
      "build",
    ])
    return arguments
  }

  /// Environment for build invocations. Merges the parent environment with
  /// `CC` and `CXX` set to a `ccache`/`sccache` wrapper when one is enabled.
  /// Both `swift build` and `xcodebuild` honor these variables, so the same
  /// wrapper applies to MLX's C/C++ Metal kernels regardless of which build
  /// system is invoked.
  private func buildEnvironment() throws -> [String: String] {
    var environmentMap = ProcessInfo.processInfo.environment
    if let buildCacheTool = try resolveBuildCacheTool() {
      try writeLine("[build-cache] using \(buildCacheTool.name): \(buildCacheTool.executable)")
      environmentMap["CC"] = "\(buildCacheTool.executable) /usr/bin/clang"
      environmentMap["CXX"] = "\(buildCacheTool.executable) /usr/bin/clang++"
    }
    return environmentMap
  }

  private func resolveBuildCacheTool() throws -> BuildCacheTool? {
    if let selectedCache = environment.values["LMD_BUILD_CACHE"], !selectedCache.isEmpty {
      return try explicitlySelectedBuildCacheTool(selectedCache)
    }

    let sccacheEnabled = isEnabled(environment.values["LMD_ENABLE_SCCACHE"])
    let ccacheEnabled = isEnabled(environment.values["LMD_ENABLE_CCACHE"])

    if sccacheEnabled, let executable = findExecutable("sccache") {
      return BuildCacheTool(name: "sccache", executable: executable)
    }
    if sccacheEnabled {
      try writeLine("[build-cache] LMD_ENABLE_SCCACHE is set, but sccache was not found; building without sccache")
    }

    if ccacheEnabled, let executable = findExecutable("ccache") {
      return BuildCacheTool(name: "ccache", executable: executable)
    }
    if ccacheEnabled {
      try writeLine("[build-cache] LMD_ENABLE_CCACHE is set, but ccache was not found; building without ccache")
    }

    return nil
  }

  private func explicitlySelectedBuildCacheTool(_ selectedCache: String) throws -> BuildCacheTool? {
    let normalizedCache = selectedCache.lowercased()
    if normalizedCache == "none" || normalizedCache == "off" || normalizedCache == "0" {
      return nil
    }
    if normalizedCache == "sccache" || normalizedCache == "ccache" {
      if let executable = findExecutable(normalizedCache) {
        return BuildCacheTool(name: normalizedCache, executable: executable)
      }
      try writeLine("[build-cache] LMD_BUILD_CACHE=\(normalizedCache), but \(normalizedCache) was not found; building without cache")
      return nil
    }
    throw ToolError.usage("LMD_BUILD_CACHE must be sccache, ccache, none, off, or 0")
  }

  private func isEnabled(_ rawValue: String?) -> Bool {
    guard let rawValue else {
      return false
    }
    let normalizedValue = rawValue.lowercased()
    return ["1", "true", "yes", "on"].contains(normalizedValue)
  }

  private func findExecutable(_ name: String) -> String? {
    if name.contains("/") {
      return fileManager.isExecutableFile(atPath: name) ? name : nil
    }

    let pathValue = environment.value("PATH", default: "/usr/bin:/bin:/usr/sbin:/sbin")
    for directory in pathValue.split(separator: ":") {
      let candidate = URL(fileURLWithPath: String(directory)).appendingPathComponent(name)
      if fileManager.isExecutableFile(atPath: candidate.path) {
        return candidate.path
      }
    }
    return nil
  }

  private func buildDirectory(configuration: String) -> URL {
    productsDirectory().appendingPathComponent("Build").appendingPathComponent(configuration)
  }

  private func derivedProductsDirectory(configuration: String) -> URL {
    repoRoot.appendingPathComponent("Derived/Build/Products").appendingPathComponent(configuration)
  }

  private func releaseBuildDirectory() -> URL {
    if let override = environment.values["LMD_BUILD_DIR"], !override.isEmpty {
      return URL(fileURLWithPath: override, relativeTo: repoRoot).standardizedFileURL
    }
    if let binaryDirectory = environment.values["LMD_BINARY_DIR"], !binaryDirectory.isEmpty {
      return URL(fileURLWithPath: binaryDirectory, relativeTo: repoRoot).standardizedFileURL
    }
    return buildDirectory(configuration: "Release")
  }

  /// SwiftPM's product directory: `.build/<configuration>/` relative to the
  /// repo root. Configuration is the lower-cased SwiftPM form (`debug`,
  /// `release`).
  private func swiftPackageBuildDirectory(configuration: String) -> URL {
    repoRoot
      .appendingPathComponent(".build")
      .appendingPathComponent(swiftPackageConfiguration(configuration))
  }

  /// Map an Xcode-style configuration name (`Release`, `Debug`) to the
  /// lower-cased form SwiftPM expects on `-c`.
  private func swiftPackageConfiguration(_ configuration: String) -> String {
    configuration.lowercased()
  }

  private func productsDirectory() -> URL {
    repoRoot.appendingPathComponent("Products")
  }

  private func prefixDirectory() -> URL {
    URL(fileURLWithPath: environment.value("PREFIX", default: "\(homeDirectory().path)/.local"))
      .standardizedFileURL
  }

  private func homeDirectory() -> URL {
    URL(fileURLWithPath: NSHomeDirectory())
  }

  private func agentPlistURL() -> URL {
    homeDirectory().appendingPathComponent("Library/LaunchAgents/io.goodkind.lmd.serve.plist")
  }

  private func stageRuntimeResources(for configuration: String) throws {
    let destination = buildDirectory(configuration: configuration)
    let resourceNames = ["mlx.metallib", "default.metallib", "mlx-swift_Cmlx.bundle"]
    var copied = Set<String>()
    for searchRoot in runtimeResourceSearchRoots(configuration: configuration) {
      guard fileManager.fileExists(atPath: searchRoot.path) else {
        continue
      }
      guard let enumerator = fileManager.enumerator(at: searchRoot, includingPropertiesForKeys: nil) else {
        continue
      }
      for case let item as URL in enumerator {
        guard resourceNames.contains(item.lastPathComponent) else {
          continue
        }
        guard !copied.contains(item.lastPathComponent) else {
          continue
        }
        try copyReplacingItem(at: item, to: destination.appendingPathComponent(item.lastPathComponent))
        copied.insert(item.lastPathComponent)
        try writeLine("  staged \(item.lastPathComponent)")
      }
    }
  }

  private func runtimeResourceSearchRoots(configuration: String) -> [URL] {
    let derivedProducts = derivedProductsDirectory(configuration: configuration)
    let derived = repoRoot.appendingPathComponent("Derived")
    let xcodeDerived = homeDirectory().appendingPathComponent("Library/Developer/Xcode/DerivedData")
    return [derivedProducts, derived, xcodeDerived]
  }

  private func copyRuntimeResources(from sourceDirectory: URL, to destinationDirectory: URL) throws {
    for resourceName in ["mlx.metallib", "default.metallib", "mlx-swift_Cmlx.bundle"] {
      let source = sourceDirectory.appendingPathComponent(resourceName)
      if fileManager.fileExists(atPath: source.path) {
        try copyReplacingItem(at: source, to: destinationDirectory.appendingPathComponent(resourceName))
        try writeLine("  installed \(destinationDirectory.appendingPathComponent(resourceName).path)")
      }
    }
  }

  private func signTargets(
    _ targets: [String],
    identity: String,
    bundleIdentifierPrefix: String
  ) throws {
    for target in targets {
      let inputURL = URL(fileURLWithPath: target, relativeTo: repoRoot).standardizedFileURL
      let binaryPath = fileManager.fileExists(atPath: inputURL.path)
        ? inputURL
        : releaseBuildDirectory().appendingPathComponent(target)
      try signPath(
        binaryPath,
        identity: identity,
        identifier: "\(bundleIdentifierPrefix).\(binaryPath.lastPathComponent)"
      )
    }
    for bundle in resourceBundlesToSign() {
      let bundleName = bundle.deletingPathExtension().lastPathComponent
      try signPath(
        bundle,
        identity: identity,
        identifier: "\(bundleIdentifierPrefix).\(bundleName)"
      )
    }
  }

  /// Codesign a single Mach-O or bundle with the Hardened Runtime and a
  /// secure timestamp, then verify the signature.
  private func signPath(_ path: URL, identity: String, identifier: String) throws {
    guard fileManager.fileExists(atPath: path.path) else {
      throw ToolError.failure("sign: not found: \(path.path)")
    }
    try runPassthrough(
      "codesign",
      [
        "--sign",
        identity,
        "--identifier",
        identifier,
        "--options",
        "runtime",
        "--timestamp",
        "--force",
        path.path,
      ]
    )
    try runPassthrough("codesign", ["--verify", "--strict", "--verbose=2", path.path])
  }

  /// Resource bundles in the staged release directory that need a real
  /// signature for notarization. Today this is just the MLX shader bundle,
  /// but any future `*.bundle` Tuist drops alongside the binaries gets
  /// picked up automatically.
  private func resourceBundlesToSign() -> [URL] {
    let staging = releaseBuildDirectory()
    guard let contents = try? fileManager.contentsOfDirectory(
      at: staging,
      includingPropertiesForKeys: nil
    ) else {
      return []
    }
    return contents.filter { $0.pathExtension == "bundle" }
  }

  private func stageSignedBinaries(into directory: URL) throws {
    for binary in productBinaries {
      let source = releaseBuildDirectory().appendingPathComponent(binary)
      guard fileManager.fileExists(atPath: source.path) else {
        throw ToolError.failure("[notarize] missing \(source.path); run sign first")
      }
      try runPassthrough("codesign", ["--verify", "--strict", source.path])
      try copyReplacingItem(at: source, to: directory.appendingPathComponent(binary))
    }
    try stageCompatibilityLinks(in: directory)
    try copyRuntimeResources(from: releaseBuildDirectory(), to: directory)
    for bundle in resourceBundlesToSign() {
      try runPassthrough("codesign", ["--verify", "--strict", bundle.path])
    }
  }

  private func localSigningConfig() throws -> [String: String] {
    let signingURL = repoRoot.appendingPathComponent("config/signing.env")
    guard fileManager.fileExists(atPath: signingURL.path) else {
      throw ToolError.failure("missing \(signingURL.path); cp config/signing.env.example config/signing.env and fill in your values")
    }
    return try parseKeyValueFile(signingURL)
  }

  private func parseKeyValueFile(_ url: URL) throws -> [String: String] {
    let content = try String(contentsOf: url, encoding: .utf8)
    var values: [String: String] = [:]
    for rawLine in content.components(separatedBy: .newlines) {
      let line = rawLine.trimmingCharacters(in: .whitespaces)
      if line.isEmpty || line.hasPrefix("#") {
        continue
      }
      let parts = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
      if parts.count != 2 {
        continue
      }
      let key = String(parts[0]).trimmingCharacters(in: .whitespaces)
      var value = String(parts[1]).trimmingCharacters(in: .whitespaces)
      if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 {
        value.removeFirst()
        value.removeLast()
      }
      values[key] = value
    }
    return values
  }

  private func sourceSwiftFiles(excludingPathComponent excluded: String) throws -> [URL] {
    let sources = repoRoot.appendingPathComponent("Sources")
    guard let enumerator = fileManager.enumerator(at: sources, includingPropertiesForKeys: nil) else {
      return []
    }
    var files: [URL] = []
    for case let file as URL in enumerator {
      if file.pathComponents.contains(excluded) {
        enumerator.skipDescendants()
        continue
      }
      if file.pathExtension == "swift" {
        files.append(file)
      }
    }
    return files
  }

  private func relativePath(_ url: URL) -> String {
    let root = repoRoot.path
    if url.path.hasPrefix(root) {
      return String(url.path.dropFirst(root.count + 1))
    }
    return url.path
  }

  @discardableResult
  private func runPassthrough(
    _ executable: String,
    _ arguments: [String],
    currentDirectory: URL? = nil,
    environment: [String: String]? = nil
  ) throws -> CommandResult {
    try run(
      executable,
      arguments,
      currentDirectory: currentDirectory,
      environment: environment,
      captureOutput: false
    )
  }

  private func runCaptured(
    _ executable: String,
    _ arguments: [String],
    currentDirectory: URL? = nil,
    environment: [String: String]? = nil
  ) throws -> CommandResult {
    try run(
      executable,
      arguments,
      currentDirectory: currentDirectory,
      environment: environment,
      captureOutput: true
    )
  }

  private func run(
    _ executable: String,
    _ arguments: [String],
    currentDirectory: URL?,
    environment: [String: String]?,
    captureOutput: Bool
  ) throws -> CommandResult {
    let process = Process()
    if executable.hasPrefix("/") || executable.hasPrefix(".") {
      process.executableURL = URL(fileURLWithPath: executable)
      process.arguments = arguments
    } else {
      process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
      process.arguments = [executable] + arguments
    }
    process.currentDirectoryURL = currentDirectory ?? repoRoot
    process.environment = environment ?? ProcessInfo.processInfo.environment

    let pipe = Pipe()
    if captureOutput {
      process.standardOutput = pipe
      process.standardError = pipe
    }

    try process.run()
    process.waitUntilExit()

    var output = ""
    if captureOutput {
      let data = pipe.fileHandleForReading.readDataToEndOfFile()
      output = String(data: data, encoding: .utf8) ?? ""
    }

    if process.terminationStatus != 0 {
      if captureOutput, !output.isEmpty {
        try write(output)
      }
      throw ToolError.failure("command failed (\(process.terminationStatus)): \(([executable] + arguments).joined(separator: " "))")
    }

    return CommandResult(status: process.terminationStatus, output: output)
  }

  private func currentUserKeychains() throws -> [String] {
    let result = try runCaptured("security", ["list-keychains", "-d", "user"])
    return result.output
      .components(separatedBy: .newlines)
      .map { line in
        line.trimmingCharacters(in: .whitespacesAndNewlines)
          .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
      }
      .filter { !$0.isEmpty }
  }

  private func decodeBase64Environment(_ name: String) throws -> Data {
    let value = try environment.required(name)
    guard let data = Data(base64Encoded: value) else {
      throw ToolError.failure("\(name) is not valid base64")
    }
    return data
  }

  private func appendGitHubOutput(name: String, value: String) throws {
    guard let path = environment.values["GITHUB_OUTPUT"], !path.isEmpty else {
      return
    }
    try appendLine("\(name)=\(value)", to: URL(fileURLWithPath: path))
  }

  private func appendGitHubEnvironment(name: String, value: String) throws {
    guard let path = environment.values["GITHUB_ENV"], !path.isEmpty else {
      return
    }
    try appendLine("\(name)=\(value)", to: URL(fileURLWithPath: path))
  }

  private func appendLine(_ line: String, to url: URL) throws {
    let data = Data((line + "\n").utf8)
    if fileManager.fileExists(atPath: url.path) {
      let handle = try FileHandle(forWritingTo: url)
      defer {
        try? handle.close()
      }
      try handle.seekToEnd()
      try handle.write(contentsOf: data)
    } else {
      try data.write(to: url, options: .atomic)
    }
  }

  private func removeIfExists(_ url: URL) throws {
    if fileManager.fileExists(atPath: url.path) {
      try fileManager.removeItem(at: url)
    }
  }

  private func copyReplacingItem(at source: URL, to destination: URL) throws {
    try removeIfExists(destination)
    try fileManager.copyItem(at: source, to: destination)
  }

  private func stageCompatibilityLinks(in directory: URL) throws {
    for (linkName, destinationName) in compatibilityCommandLinks {
      let linkPath = directory.appendingPathComponent(linkName)
      try removeIfExists(linkPath)
      try fileManager.createSymbolicLink(atPath: linkPath.path, withDestinationPath: destinationName)
      try writeLine("  linked \(linkName) -> \(destinationName)")
    }
  }

  private func temporaryDirectory(prefix: String) throws -> URL {
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("\(prefix).\(UUID().uuidString)")
    try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  private func temporaryFileURL(prefix: String, suffix: String) -> URL {
    URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("\(prefix).\(UUID().uuidString)\(suffix)")
  }

  private func artifactStamp() -> String {
    artifactDateFormatter().string(from: Date())
  }

  private func artifactDateFormatter() -> DateFormatter {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyyMMdd-HHmmss"
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    return formatter
  }

  private func releaseTagFormatter() -> DateFormatter {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyyMMddHHmm"
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    return formatter
  }

  private func logDateFormatter() -> DateFormatter {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd HH:mm:ssZ"
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    return formatter
  }

  private func prompt(_ message: String) -> String {
    try? write(message)
    return readLine() ?? ""
  }

  private func writeLine(_ message: String) throws {
    try write(message + "\n")
  }

  private func write(_ message: String) throws {
    try FileHandle.standardOutput.write(contentsOf: Data(message.utf8))
  }
}

final class SmokeRunner {
  private let configuration: SmokeConfiguration
  private let fileManager = FileManager.default
  private let jsonDecoder = JSONDecoder()
  private let jsonEncoder = JSONEncoder()
  private var brokerProcess: Process?
  private var temporaryDirectory: URL?

  init(configuration: SmokeConfiguration) {
    self.configuration = configuration
  }

  func run() async throws {
    temporaryDirectory = try makeTemporaryDirectory()
    defer {
      cleanup()
    }

    if configuration.useRunningDaemon {
      writeLine("using running lmd-serve at \(configuration.baseURL.absoluteString)")
    } else {
      try startBroker()
    }

    try await waitForHealth()
    writeLine("health OK")
    try await assertModels()
    try await assertLoadedModels()

    if let videoSampleFile = configuration.videoSampleFile {
      try await runVideoAcceptance(videoSampleFile: videoSampleFile)
    }

    writeLine("smoke-lmd-serve: PASS")
  }

  private func startBroker() throws {
    guard let brokerBinary = resolveBrokerBinary() else {
      throw ToolError.failure("binary missing under \(configuration.binaryDirectory.path); run 'make build' first or set LMD_BINARY_DIR")
    }

    writeLine("starting lmd-serve at \(configuration.baseURL.absoluteString)")
    let process = Process()
    process.executableURL = brokerBinary
    process.arguments = []
    var environment = ProcessInfo.processInfo.environment
    environment["LMD_HOST"] = configuration.host
    environment["LMD_PORT"] = "\(configuration.port)"
    environment["LMD_DISABLE_XPC"] = "1"
    process.environment = environment
    try process.run()
    brokerProcess = process
  }

  private func resolveBrokerBinary() -> URL? {
    for candidateRelativePath in ["lmd-serve", "lmd_serve", "Release/lmd-serve", "Release/lmd_serve"] {
      let candidate = configuration.binaryDirectory.appendingPathComponent(candidateRelativePath)
      if fileManager.isExecutableFile(atPath: candidate.path) {
        return candidate
      }
    }
    return nil
  }

  private func waitForHealth() async throws {
    let deadline = Date().addingTimeInterval(30)
    var lastError: Error?
    while Date() < deadline {
      try assertBrokerStillRunning()
      do {
        let response = try await request(path: "health", timeout: 2)
        if response.statusCode == 200 {
          return
        }
      } catch {
        lastError = error
      }
      try assertBrokerStillRunning()
      try await Task.sleep(nanoseconds: 1_000_000_000)
    }

    if let lastError {
      throw ToolError.failure("daemon failed to come up: \(lastError)")
    }
    throw ToolError.failure("daemon failed to come up")
  }

  private func assertBrokerStillRunning() throws {
    guard let brokerProcess else {
      return
    }
    guard !brokerProcess.isRunning else {
      return
    }
    throw ToolError.failure("daemon exited before /health became ready with status \(brokerProcess.terminationStatus)")
  }

  private func assertModels() async throws {
    let response = try await request(path: "v1/models", timeout: 3)
    guard response.statusCode == 200 else {
      throw ToolError.failure("GET /v1/models failed with HTTP \(response.statusCode); response body: \(bodySnippet(response.data))")
    }
    let models = try jsonDecoder.decode(ModelsResponse.self, from: response.data)
    guard models.object == "list" else {
      throw ToolError.failure("bad /v1/models object field: \(models.object)")
    }
    writeLine("models: \(models.data.count)")
  }

  private func assertLoadedModels() async throws {
    let response = try await request(path: "swiftlmd/loaded", timeout: 3)
    guard response.statusCode == 200 else {
      throw ToolError.failure("GET /swiftlmd/loaded failed with HTTP \(response.statusCode); response body: \(bodySnippet(response.data))")
    }
    let loaded = try jsonDecoder.decode(LoadedModelsResponse.self, from: response.data)
    if configuration.useRunningDaemon {
      writeLine("loaded-models observed: count=\(loaded.models.count) allocated_gb=\(loaded.allocatedGB)")
      return
    }
    guard loaded.models.isEmpty else {
      throw ToolError.failure("expected empty loaded models, got \(loaded.models.count)")
    }
    guard loaded.allocatedGB == 0 else {
      throw ToolError.failure("expected 0 GB, got \(loaded.allocatedGB)")
    }
    writeLine("loaded-models empty OK")
  }

  private func runVideoAcceptance(videoSampleFile: URL) async throws {
    let sampleCopy = try copyVideoSampleToTemporaryDirectory(videoSampleFile)
    let requestBody = try buildVideoRequest(videoFile: sampleCopy)
    writeLine("video acceptance: POST /v1/chat/completions model=\(configuration.videoModel) sample=\(sampleCopy.lastPathComponent)")

    let response = try await request(
      path: "v1/chat/completions",
      method: "POST",
      body: requestBody,
      timeout: configuration.videoTimeoutSeconds
    )
    let responseText = bodySnippet(response.data)

    // The spec at plan/VIDEO_ROUTING_FINAL_DECISION.md requires HTTP 200 with a
    // populated assistant message because frame sampling at infinite tolerance
    // succeeds against both the 1-frame and 2-second fixtures.
    guard response.statusCode == 200 else {
      throw ToolError.failure("video acceptance failed with HTTP \(response.statusCode); response body: \(responseText)")
    }
    let completion = try jsonDecoder.decode(ChatCompletionResponse.self, from: response.data)
    guard let firstChoice = completion.choices.first else {
      throw ToolError.failure("video acceptance returned HTTP 200 but choices was empty; response body: \(responseText)")
    }
    guard firstChoice.message.content.isNonEmpty else {
      throw ToolError.failure("video acceptance returned HTTP 200 but choices.0.message.content was empty; response body: \(responseText)")
    }
    writeLine("video acceptance OK: non-empty VLM response from \(configuration.videoModel)")
  }

  private func copyVideoSampleToTemporaryDirectory(_ videoSampleFile: URL) throws -> URL {
    guard fileManager.fileExists(atPath: videoSampleFile.path) else {
      throw ToolError.failure("video sample missing at \(videoSampleFile.path)")
    }
    guard fileManager.isReadableFile(atPath: videoSampleFile.path) else {
      throw ToolError.failure("video sample is not readable at \(videoSampleFile.path)")
    }
    let resourceValues = try videoSampleFile.resourceValues(forKeys: [.isRegularFileKey])
    guard resourceValues.isRegularFile == true else {
      throw ToolError.failure("video sample must point to a regular file at \(videoSampleFile.path)")
    }
    let videoExtension = videoSampleFile.pathExtension.lowercased()
    guard supportedVideoExtensions.contains(videoExtension) else {
      throw ToolError.failure("video sample must use a route-supported video extension")
    }
    guard let temporaryDirectory else {
      throw ToolError.failure("temporary directory was not initialized")
    }

    let destination = temporaryDirectory.appendingPathComponent("lmd-video-sample.\(videoExtension)")
    try fileManager.copyItem(at: videoSampleFile, to: destination)
    return destination.standardizedFileURL
  }

  private func buildVideoRequest(videoFile: URL) throws -> Data {
    let request = VideoChatRequest(
      model: configuration.videoModel,
      messages: [
        VideoChatRequest.Message(
          role: "user",
          content: [
            .text("Describe the visible motion in this video in one concise sentence."),
            .video(url: videoFile),
          ]
        )
      ],
      maxTokens: configuration.videoMaxTokens,
      temperature: 0
    )
    return try jsonEncoder.encode(request)
  }

  private func request(
    path: String,
    method: String = "GET",
    body: Data? = nil,
    timeout: TimeInterval
  ) async throws -> HTTPResult {
    let url = configuration.baseURL.appendingPathComponent(path)
    var request = URLRequest(url: url, timeoutInterval: timeout)
    request.httpMethod = method
    request.httpBody = body
    if body != nil {
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    }
    let (data, response) = try await URLSession.shared.data(for: request)
    let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
    return HTTPResult(statusCode: statusCode, data: data)
  }

  private func makeTemporaryDirectory() throws -> URL {
    let temporaryURL = fileManager.temporaryDirectory
      .appendingPathComponent("lmd-smoke-\(UUID().uuidString)", isDirectory: true)
    try fileManager.createDirectory(at: temporaryURL, withIntermediateDirectories: true)
    return temporaryURL
  }

  private func cleanup() {
    if let brokerProcess {
      brokerProcess.terminate()
      if !waitForProcessExit(brokerProcess, timeout: 3) {
        kill(brokerProcess.processIdentifier, SIGKILL)
      }
    }
    if let temporaryDirectory {
      try? fileManager.removeItem(at: temporaryDirectory)
    }
  }
}

extension Dictionary where Key == String, Value == String {
  func required(_ key: String) throws -> String {
    guard let value = self[key], !value.isEmpty else {
      throw ToolError.failure("\(key) not set")
    }
    return value
  }
}

func bodySnippet(_ data: Data, limit: Int = 4_096) -> String {
  let body = String(data: data, encoding: .utf8) ?? "<non-utf8 response>"
  guard body.count > limit else {
    return body
  }
  let endIndex = body.index(body.startIndex, offsetBy: limit)
  return "\(body[..<endIndex])...<truncated>"
}

func waitForProcessExit(_ process: Process, timeout: TimeInterval) -> Bool {
  let deadline = Date().addingTimeInterval(timeout)
  while process.isRunning {
    if Date() >= deadline {
      return false
    }
    Thread.sleep(forTimeInterval: 0.05)
  }
  return true
}

func writeLine(_ message: String, to handle: FileHandle = .standardOutput) {
  let data = Data((message + "\n").utf8)
  handle.write(data)
}

do {
  let tool = try DevTool()
  try await tool.run(arguments: Array(CommandLine.arguments.dropFirst()))
  exit(EXIT_SUCCESS)
} catch let error as ToolError {
  writeLine(error.description, to: .standardError)
  exit(EXIT_FAILURE)
} catch {
  writeLine("unexpected error: \(error)", to: .standardError)
  exit(EXIT_FAILURE)
}
