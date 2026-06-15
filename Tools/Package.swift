// swift-tools-version: 6.2
//
//  Package.swift
//  lmd-dev
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-06-14.
//  Copyright © 2026, all rights reserved.
//

import Foundation
import PackageDescription

// swift-makefile is consumed upstream by default. SWIFT_MK_DEV_DIR overrides it to a
// local checkout for development, the same override the make layer uses; never hardcode
// a relative path to it.
let swiftMakefileDevDir =
  ProcessInfo.processInfo.environment["SWIFT_MK_DEV_DIR"]?
  .trimmingCharacters(in: .whitespaces) ?? ""

let swiftMakefileDependency: Package.Dependency = {
  if !swiftMakefileDevDir.isEmpty {
    return .package(path: swiftMakefileDevDir)
  }
  return .package(url: "https://github.com/agoodkind/swift-makefile.git", branch: "main")
}()

// For a path dependency, SwiftPM derives the package identity from the checkout
// directory's basename rather than the manifest `name`, so a dev checkout in a
// worktree (e.g. `.claude/worktrees/gate-proof`) is identified by that basename.
// The upstream URL case keeps the canonical `swift-makefile` identity.
let swiftMakefilePackageName: String = {
  if !swiftMakefileDevDir.isEmpty {
    return URL(fileURLWithPath: swiftMakefileDevDir).lastPathComponent
  }
  return "swift-makefile"
}()

let package = Package(
  name: "lmd-dev",
  platforms: [
    .macOS(.v26)
  ],
  products: [
    .executable(name: "lmd-dev", targets: ["lmd-dev"])
  ],
  dependencies: [
    swiftMakefileDependency
  ],
  targets: [
    .executableTarget(
      name: "lmd-dev",
      dependencies: [
        .product(name: "SwiftMkCore", package: swiftMakefilePackageName)
      ],
      path: "lmd-dev"
    )
  ]
)
