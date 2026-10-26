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

// The root `lmd` package is consumed as a path dependency for the dependency-free
// `BrokerConfigKeys` module, the single source of truth for the broker
// configuration keys and the smoke harness's spawned-broker environment. Resolve
// the repo root from this manifest's own location so a worktree checkout works,
// and derive the package identity from its basename since SwiftPM keys a path
// dependency by directory name (`lmd` in the primary checkout, the worktree name
// in a linked worktree).
let repoRootURL = URL(fileURLWithPath: #filePath)
  .deletingLastPathComponent()
  .deletingLastPathComponent()
let repoRootPackageName = repoRootURL.lastPathComponent

var products: [Product] = [
  .executable(name: "lmd-maintenance", targets: ["lmd-maintenance"])
]
var dependencies: [Package.Dependency] = [
  swiftMakefileDependency,
  .package(url: "https://github.com/Quick/Nimble.git", exact: "14.0.0"),
  .package(url: "https://github.com/apple/swift-crypto.git", exact: "4.5.0"),
]
var targets: [Target] = [
  .executableTarget(
    name: "lmd-maintenance",
    dependencies: [
      .product(name: "SwiftMkCore", package: swiftMakefilePackageName),
      .product(name: "Crypto", package: "swift-crypto", condition: .when(platforms: [.linux])),
    ],
    path: "lmd-maintenance"
  ),
  .testTarget(
    name: "LMDMaintenanceTests",
    dependencies: [
      "lmd-maintenance",
      .product(name: "SwiftMkCore", package: swiftMakefilePackageName),
      .product(name: "Nimble", package: "Nimble"),
    ],
    path: "MaintenanceTests"
  ),
]

#if os(macOS)
  products.append(.executable(name: "lmd-dev", targets: ["lmd-dev"]))
  dependencies.append(.package(path: repoRootURL.path))
  targets.append(contentsOf: [
    .executableTarget(
      name: "lmd-dev",
      dependencies: [
        .product(name: "SwiftMkCore", package: swiftMakefilePackageName),
        .product(name: "BrokerConfigKeys", package: repoRootPackageName),
        .product(name: "SwiftLMEmbed", package: repoRootPackageName),
      ],
      path: "lmd-dev"
    ),
    .testTarget(
      name: "LMDDevTests",
      dependencies: [
        "lmd-dev",
        .product(name: "SwiftMkCore", package: swiftMakefilePackageName),
        .product(name: "AppLogger", package: repoRootPackageName),
        .product(name: "Nimble", package: "Nimble"),
      ],
      path: "Tests"
    ),
  ])
#endif

let package = Package(
  name: "lmd-dev",
  platforms: [.macOS(.v26)],
  products: products,
  dependencies: dependencies,
  targets: targets
)
