// swift-tools-version: 6.1
//
//  Package.swift
//  lmd
//
//  Created by Alex Goodkind <alex@goodkind.io> on 2026-04-18.
//  Copyright © 2026
//

import PackageDescription

let strictConcurrency: [SwiftSetting] = [
  .enableUpcomingFeature("StrictConcurrency"),
]

let package = Package(
  name: "lmd",
  platforms: [.macOS(.v14)],
  products: [
    .library(name: "AppLogger", targets: ["AppLogger"]),
    .library(name: "SwiftLMCore", targets: ["SwiftLMCore"]),
    .library(name: "SwiftLMBackend", targets: ["SwiftLMBackend"]),
    .library(name: "SwiftLMEmbed", targets: ["SwiftLMEmbed"]),
    .library(name: "SwiftLMRuntime", targets: ["SwiftLMRuntime"]),
    .library(name: "SwiftLMMonitor", targets: ["SwiftLMMonitor"]),
    .library(name: "SwiftLMTUI", targets: ["SwiftLMTUI"]),
    .library(name: "SwiftLMControl", targets: ["SwiftLMControl"]),
  ],
  dependencies: [
    .package(url: "https://github.com/hummingbird-project/hummingbird", from: "2.22.0"),
    .package(url: "https://github.com/apple/swift-log.git", from: "1.12.0"),
    .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", from: "1.2.0"),
    .package(url: "https://github.com/ml-explore/mlx-swift-lm.git", exact: "2.31.3"),
    .package(url: "https://github.com/huggingface/swift-huggingface.git", from: "0.9.0"),
  ],
  targets: [
    .target(
      name: "AppLogger",
      dependencies: [.product(name: "Logging", package: "swift-log")],
      path: "Sources/AppLogger",
      swiftSettings: strictConcurrency
    ),
    .target(
      name: "SwiftLMCore",
      dependencies: ["AppLogger"],
      path: "Sources/SwiftLMCore",
      swiftSettings: strictConcurrency
    ),
    .target(
      name: "SwiftLMBackend",
      dependencies: ["AppLogger", "SwiftLMCore"],
      path: "Sources/SwiftLMBackend",
      swiftSettings: strictConcurrency
    ),
    .target(
      name: "SwiftLMEmbed",
      dependencies: [
        "SwiftLMCore",
        "SwiftLMBackend",
        .product(name: "MLXEmbedders", package: "mlx-swift-lm"),
      ],
      path: "Sources/SwiftLMEmbed",
      swiftSettings: strictConcurrency
    ),
    .target(
      name: "SwiftLMRuntime",
      dependencies: ["AppLogger", "SwiftLMCore", "SwiftLMBackend"],
      path: "Sources/SwiftLMRuntime",
      swiftSettings: strictConcurrency
    ),
    .target(
      name: "SwiftLMMonitor",
      dependencies: ["AppLogger", "SwiftLMCore"],
      path: "Sources/SwiftLMMonitor",
      swiftSettings: strictConcurrency
    ),
    .target(
      name: "SwiftLMTUI",
      dependencies: ["AppLogger", "SwiftLMCore"],
      path: "Sources/SwiftLMTUI",
      swiftSettings: strictConcurrency
    ),
    .target(
      name: "SwiftLMControl",
      dependencies: ["AppLogger", "SwiftLMRuntime"],
      path: "Sources/SwiftLMControl",
      swiftSettings: strictConcurrency
    ),

    .executableTarget(
      name: "lmd",
      dependencies: [
        "AppLogger",
        "SwiftLMCore",
        "SwiftLMRuntime",
        "SwiftLMControl",
      ],
      path: "Sources/lmd"
    ),
    .executableTarget(
      name: "lmd-serve",
      dependencies: [
        "AppLogger",
        "SwiftLMCore",
        "SwiftLMBackend",
        "SwiftLMEmbed",
        "SwiftLMRuntime",
        "SwiftLMMonitor",
        "SwiftLMControl",
        .product(name: "Hummingbird", package: "hummingbird"),
        .product(name: "HuggingFace", package: "swift-huggingface"),
      ],
      path: "Sources/lmd-serve"
    ),
    .executableTarget(
      name: "lmd-tui",
      dependencies: ["AppLogger", "SwiftLMCore", "SwiftLMRuntime", "SwiftLMTUI", "SwiftLMControl"],
      path: "Sources/lmd-tui",
      swiftSettings: [.swiftLanguageMode(.v5)]
    ),
    .executableTarget(
      name: "lmd-bench",
      dependencies: ["AppLogger", "SwiftLMCore", "SwiftLMBackend", "SwiftLMRuntime", "SwiftLMMonitor"],
      path: "Sources/lmd-bench",
      swiftSettings: [.swiftLanguageMode(.v5)]
    ),
    .executableTarget(
      name: "lmd-qa",
      dependencies: [.product(name: "SwiftTerm", package: "SwiftTerm")],
      path: "Sources/lmd-qa",
      swiftSettings: [.swiftLanguageMode(.v5)]
    ),

    .testTarget(
      name: "AppLoggerTests",
      dependencies: ["AppLogger"],
      path: "Tests/AppLoggerTests",
      swiftSettings: strictConcurrency
    ),
    .testTarget(
      name: "SwiftLMCoreTests",
      dependencies: ["SwiftLMCore"],
      path: "Tests/SwiftLMCoreTests",
      swiftSettings: strictConcurrency
    ),
    .testTarget(
      name: "SwiftLMBackendTests",
      dependencies: ["SwiftLMBackend"],
      path: "Tests/SwiftLMBackendTests",
      swiftSettings: strictConcurrency
    ),
    .testTarget(
      name: "SwiftLMMonitorTests",
      dependencies: ["SwiftLMMonitor"],
      path: "Tests/SwiftLMMonitorTests",
      swiftSettings: strictConcurrency
    ),
    .testTarget(
      name: "SwiftLMRuntimeTests",
      dependencies: ["SwiftLMRuntime", "SwiftLMCore", "SwiftLMBackend"],
      path: "Tests/SwiftLMRuntimeTests",
      swiftSettings: strictConcurrency
    ),
    .testTarget(
      name: "SwiftLMControlTests",
      dependencies: ["SwiftLMControl"],
      path: "Tests/SwiftLMControlTests",
      swiftSettings: strictConcurrency
    ),
    .testTarget(
      name: "SwiftLMTUITests",
      dependencies: ["SwiftLMTUI"],
      path: "Tests/SwiftLMTUITests",
      exclude: ["Snapshots"],
      swiftSettings: strictConcurrency
    ),
    .testTarget(
      name: "IntegrationTests",
      dependencies: ["SwiftLMControl", "SwiftLMCore", "SwiftLMRuntime"],
      path: "Tests/IntegrationTests",
      exclude: ["smoke-lmd-serve.sh"],
      swiftSettings: strictConcurrency
    ),
  ]
)
