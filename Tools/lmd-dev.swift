#!/usr/bin/env swift
import Foundation

let forwardedArguments = Array(CommandLine.arguments.dropFirst())
let toolsPackageDirectoryName = "Tools"
let toolProductName = "lmd-dev"

func environmentArguments(_ key: String) -> [String] {
  let environmentValue = ProcessInfo.processInfo.environment[key] ?? ""
  return environmentValue.split(whereSeparator: \.isWhitespace).map(String.init)
}

func swiftBuildArguments(packagePath: String, additionalArguments: [String]) -> [String] {
  var arguments = ["swift", "build"]
  arguments.append(contentsOf: environmentArguments("SWIFT_MK_SWIFTPM_CACHE_ARGS"))
  arguments.append(contentsOf: ["--package-path", packagePath])
  arguments.append(contentsOf: additionalArguments)
  return arguments
}

do {
  let currentDirectoryURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
  let toolsPackageDirectory = currentDirectoryURL.appendingPathComponent(
    toolsPackageDirectoryName)
  let buildProcess = Process()
  buildProcess.executableURL = URL(fileURLWithPath: "/usr/bin/env")
  buildProcess.arguments = swiftBuildArguments(
    packagePath: toolsPackageDirectory.path,
    additionalArguments: ["--product", toolProductName]
  )
  buildProcess.currentDirectoryURL = currentDirectoryURL
  buildProcess.environment = ProcessInfo.processInfo.environment
  try buildProcess.run()
  buildProcess.waitUntilExit()
  guard buildProcess.terminationStatus == 0 else {
    throw NSError(domain: "LmdDevWrapper", code: Int(buildProcess.terminationStatus))
  }

  let binPathProcess = Process()
  let outputPipe = Pipe()
  binPathProcess.executableURL = URL(fileURLWithPath: "/usr/bin/env")
  binPathProcess.arguments = swiftBuildArguments(
    packagePath: toolsPackageDirectory.path,
    additionalArguments: ["--show-bin-path"]
  )
  binPathProcess.currentDirectoryURL = currentDirectoryURL
  binPathProcess.environment = ProcessInfo.processInfo.environment
  binPathProcess.standardOutput = outputPipe
  binPathProcess.standardError = outputPipe
  try binPathProcess.run()
  binPathProcess.waitUntilExit()

  let binPathData = outputPipe.fileHandleForReading.readDataToEndOfFile()
  let binPath =
    String(data: binPathData, encoding: .utf8)?
    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
  guard binPathProcess.terminationStatus == 0, !binPath.isEmpty else {
    throw NSError(domain: "LmdDevWrapper", code: Int(binPathProcess.terminationStatus))
  }

  let toolBinary = URL(fileURLWithPath: binPath).appendingPathComponent(toolProductName)
  let toolProcess = Process()
  toolProcess.executableURL = toolBinary
  toolProcess.arguments = forwardedArguments
  toolProcess.currentDirectoryURL = currentDirectoryURL
  toolProcess.environment = ProcessInfo.processInfo.environment
  try toolProcess.run()
  toolProcess.waitUntilExit()
  guard toolProcess.terminationStatus == 0 else {
    let renderedCommand = ([toolBinary.path] + forwardedArguments).joined(separator: " ")
    throw NSError(
      domain: "LmdDevWrapper",
      code: Int(toolProcess.terminationStatus),
      userInfo: [
        NSLocalizedDescriptionKey:
          "\(renderedCommand) failed with status \(toolProcess.terminationStatus)"
      ]
    )
  }
} catch {
  FileHandle.standardError.write(Data("failed to start lmd-dev: \(error)\n".utf8))
  throw error
}
