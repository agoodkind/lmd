// swift-tools-version: 6.2
//
//  Package.swift
//  lmd
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-04-18.
//  Copyright © 2026, all rights reserved.
//

import PackageDescription

let strictConcurrency: [SwiftSetting] = [
  .enableUpcomingFeature("StrictConcurrency")
]

let package = Package(
  name: "lmd",
  platforms: [.macOS(.v26)],
  products: [
    .library(name: "AppLogger", targets: ["AppLogger"]),
    .library(name: "SwiftLMCore", targets: ["SwiftLMCore"]),
    .library(name: "SwiftLMMetrics", targets: ["SwiftLMMetrics"]),
    .library(name: "SwiftLMMetricsOTel", targets: ["SwiftLMMetricsOTel"]),
    .library(name: "SwiftLMTrace", targets: ["SwiftLMTrace"]),
    .library(name: "SwiftLMBackend", targets: ["SwiftLMBackend"]),
    .library(name: "SwiftLMEmbed", targets: ["SwiftLMEmbed"]),
    .library(name: "SwiftLMRuntime", targets: ["SwiftLMRuntime"]),
    .library(name: "SwiftLMMonitor", targets: ["SwiftLMMonitor"]),
    .library(name: "SwiftLMTUI", targets: ["SwiftLMTUI"]),
    .library(name: "SwiftLMControl", targets: ["SwiftLMControl"]),
    .library(name: "LMDServeSupport", targets: ["LMDServeSupport"]),
    .library(name: "SwiftLMHostProtocol", targets: ["SwiftLMHostProtocol"]),
  ],
  dependencies: [
    .package(url: "https://github.com/apple/swift-argument-parser", from: "1.7.0"),
    .package(url: "https://github.com/hummingbird-project/hummingbird", from: "2.22.0"),
    .package(url: "https://github.com/apple/swift-nio-transport-services.git", from: "1.23.0"),
    .package(url: "https://github.com/apple/swift-log.git", from: "1.12.0"),
    .package(url: "https://github.com/apple/swift-metrics.git", from: "2.5.0"),
    .package(url: "https://github.com/apple/swift-distributed-tracing.git", from: "1.1.0"),
    .package(url: "https://github.com/swift-otel/swift-otel.git", from: "1.0.0"),
    .package(url: "https://github.com/swift-server/swift-service-lifecycle.git", from: "2.6.0"),
    .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", from: "1.2.0"),
    .package(url: "https://github.com/Quick/Nimble.git", from: "14.0.0"),
    .package(
      url: "https://github.com/agoodkind/mlx-swift-lm.git",
      revision: "9d77504276de8113b1f5be3a519c2b9d35938ebc"),
    .package(url: "https://github.com/agoodkind/mlx-swift.git", branch: "main"),
    .package(url: "https://github.com/huggingface/swift-huggingface.git", from: "0.9.0"),
    .package(url: "https://github.com/huggingface/swift-transformers.git", from: "1.3.2"),
    .package(url: "https://github.com/agoodkind/macos-smc-fan.git", branch: "main"),
  ],
  targets: [
    .target(
      name: "AppLogger",
      dependencies: [.product(name: "Logging", package: "swift-log")],
      path: "Sources/AppLogger",
      swiftSettings: strictConcurrency
    ),
    .target(
      name: "SwiftLMHostProtocol",
      dependencies: [],
      path: "Sources/SwiftLMHostProtocol",
      swiftSettings: strictConcurrency
    ),
    .target(
      name: "SwiftLMCore",
      dependencies: [],
      path: "Sources/SwiftLMCore",
      swiftSettings: strictConcurrency
    ),
    .target(
      name: "SwiftLMMetrics",
      dependencies: [
        .product(name: "Metrics", package: "swift-metrics"),
        .product(name: "Tracing", package: "swift-distributed-tracing"),
      ],
      path: "Sources/SwiftLMMetrics",
      swiftSettings: strictConcurrency
    ),
    .target(
      name: "SwiftLMMetricsOTel",
      dependencies: [
        "SwiftLMMetrics",
        .product(name: "Metrics", package: "swift-metrics"),
        .product(name: "Instrumentation", package: "swift-distributed-tracing"),
        .product(name: "OTel", package: "swift-otel"),
        .product(name: "ServiceLifecycle", package: "swift-service-lifecycle"),
      ],
      path: "Sources/SwiftLMMetricsOTel",
      swiftSettings: strictConcurrency
    ),
    .target(
      name: "SwiftLMTrace",
      dependencies: [
        "AppLogger",
        "SwiftLMMetrics",
        .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
      ],
      path: "Sources/SwiftLMTrace",
      swiftSettings: strictConcurrency
    ),
    .target(
      name: "SwiftLMBackend",
      dependencies: [
        "AppLogger",
        "SwiftLMCore",
        .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
        .product(name: "MLXVLM", package: "mlx-swift-lm"),
        .product(name: "MLXHuggingFace", package: "mlx-swift-lm"),
        .product(name: "Tokenizers", package: "swift-transformers"),
      ],
      path: "Sources/SwiftLMBackend",
      swiftSettings: strictConcurrency
    ),
    .target(
      name: "SwiftLMEmbed",
      dependencies: [
        "AppLogger",
        "SwiftLMCore",
        "SwiftLMBackend",
        "SwiftLMTrace",
        "SwiftLMMetrics",
        .product(name: "MLXEmbedders", package: "mlx-swift-lm"),
        .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
        .product(name: "MLXHuggingFace", package: "mlx-swift-lm"),
        .product(name: "Tokenizers", package: "swift-transformers"),
      ],
      path: "Sources/SwiftLMEmbed",
      swiftSettings: strictConcurrency
    ),
    .target(
      name: "SwiftLMRuntime",
      dependencies: [
        "AppLogger",
        "SwiftLMCore",
        "SwiftLMTrace",
        "SwiftLMHostProtocol",
        .product(name: "SMCFanXPCClient", package: "macos-smc-fan"),
      ],
      path: "Sources/SwiftLMRuntime",
      swiftSettings: strictConcurrency
    ),
    .target(
      name: "SwiftLMMonitor",
      dependencies: ["AppLogger"],
      path: "Sources/SwiftLMMonitor",
      swiftSettings: strictConcurrency
    ),
    .target(
      name: "SwiftLMTUI",
      dependencies: ["AppLogger"],
      path: "Sources/SwiftLMTUI",
      swiftSettings: strictConcurrency
    ),
    .target(
      name: "SwiftLMControl",
      dependencies: ["AppLogger", "SwiftLMCore", "SwiftLMRuntime"],
      path: "Sources/SwiftLMControl",
      swiftSettings: strictConcurrency
    ),
    .target(
      name: "LMDTUIHost",
      dependencies: ["AppLogger", "SwiftLMCore", "SwiftLMRuntime", "SwiftLMTUI", "SwiftLMControl"],
      path: "Sources/lmd-tui",
      swiftSettings: [.swiftLanguageMode(.v5)]
    ),
    .target(
      name: "LMDBenchTool",
      dependencies: ["AppLogger", "SwiftLMBackend", "SwiftLMRuntime", "SwiftLMMonitor"],
      path: "Sources/lmd-bench",
      swiftSettings: [.swiftLanguageMode(.v5)]
    ),
    .target(
      name: "LMDQATool",
      dependencies: [.product(name: "SwiftTerm", package: "SwiftTerm")],
      path: "Sources/lmd-qa",
      swiftSettings: [.swiftLanguageMode(.v5)]
    ),
    .target(
      name: "LMDServeSupport",
      dependencies: [
        "AppLogger",
        "SwiftLMCore",
        "SwiftLMBackend",
        "SwiftLMControl",
        "SwiftLMRuntime",
        "SwiftLMTrace",
        "SwiftLMMetrics",
        "SwiftLMHostProtocol",
        .product(name: "Hummingbird", package: "hummingbird"),
        .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
      ],
      path: "Sources/LMDServeSupport",
      swiftSettings: strictConcurrency
    ),

    .executableTarget(
      name: "lmd",
      dependencies: [
        .product(name: "ArgumentParser", package: "swift-argument-parser"),
        "AppLogger",
        "SwiftLMCore",
        "SwiftLMRuntime",
        "SwiftLMControl",
        "LMDTUIHost",
        "LMDBenchTool",
        "LMDQATool",
      ],
      path: "Sources/lmd"
    ),
    .executableTarget(
      name: "lmd-model-host",
      dependencies: [
        "AppLogger",
        "SwiftLMCore",
        "SwiftLMBackend",
        "SwiftLMEmbed",
        "SwiftLMMetrics",
        "SwiftLMMetricsOTel",
        "SwiftLMTrace",
        "SwiftLMHostProtocol",
        "LMDServeSupport",
        .product(name: "MLX", package: "mlx-swift"),
      ],
      path: "Sources/lmd-model-host"
    ),
    .executableTarget(
      name: "lmd-serve",
      dependencies: [
        "AppLogger",
        "SwiftLMCore",
        "SwiftLMEmbed",
        "SwiftLMRuntime",
        "SwiftLMMonitor",
        "SwiftLMControl",
        "SwiftLMMetrics",
        "SwiftLMMetricsOTel",
        "SwiftLMTrace",
        "SwiftLMHostProtocol",
        "LMDServeSupport",
        .product(name: "Hummingbird", package: "hummingbird"),
        .product(name: "NIOTransportServices", package: "swift-nio-transport-services"),
        .product(name: "HuggingFace", package: "swift-huggingface"),
      ],
      path: "Sources/lmd-serve"
    ),
    .testTarget(
      name: "AppLoggerTests",
      dependencies: ["AppLogger"],
      path: "Tests/AppLoggerTests",
      swiftSettings: strictConcurrency
    ),
    .testTarget(
      name: "SwiftLMCoreTests",
      dependencies: [
        "SwiftLMCore",
        .product(name: "Nimble", package: "Nimble"),
      ],
      path: "Tests/SwiftLMCoreTests",
      swiftSettings: strictConcurrency
    ),
    .testTarget(
      name: "SwiftLMBackendTests",
      dependencies: [
        "SwiftLMBackend",
        "SwiftLMCore",
        .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
        .product(name: "Nimble", package: "Nimble"),
      ],
      path: "Tests/SwiftLMBackendTests",
      swiftSettings: strictConcurrency
    ),
    .testTarget(
      name: "SwiftLMEmbedTests",
      dependencies: [
        "SwiftLMEmbed",
        "SwiftLMCore",
        .product(name: "MLX", package: "mlx-swift"),
        .product(name: "Nimble", package: "Nimble"),
      ],
      path: "Tests/SwiftLMEmbedTests",
      swiftSettings: strictConcurrency
    ),
    .testTarget(
      name: "SwiftLMMonitorTests",
      dependencies: [
        "SwiftLMMonitor",
        .product(name: "Nimble", package: "Nimble"),
      ],
      path: "Tests/SwiftLMMonitorTests",
      swiftSettings: strictConcurrency
    ),
    .testTarget(
      name: "LMDBenchToolTests",
      dependencies: [
        "LMDBenchTool",
        .product(name: "Nimble", package: "Nimble"),
      ],
      path: "Tests/LMDBenchToolTests",
      swiftSettings: strictConcurrency
    ),
    .testTarget(
      name: "SwiftLMMetricsTests",
      dependencies: [
        "SwiftLMMetrics",
        .product(name: "Metrics", package: "swift-metrics"),
        .product(name: "Nimble", package: "Nimble"),
      ],
      path: "Tests/SwiftLMMetricsTests",
      swiftSettings: strictConcurrency
    ),
    .testTarget(
      name: "SwiftLMRuntimeTests",
      dependencies: [
        "SwiftLMRuntime",
        "SwiftLMCore",
        "SwiftLMHostProtocol",
        "SwiftLMTrace",
        .product(name: "Nimble", package: "Nimble"),
      ],
      path: "Tests/SwiftLMRuntimeTests",
      swiftSettings: strictConcurrency
    ),
    .testTarget(
      name: "SwiftLMControlTests",
      dependencies: [
        "SwiftLMControl",
        "SwiftLMCore",
        "SwiftLMRuntime",
        .product(name: "Nimble", package: "Nimble"),
      ],
      path: "Tests/SwiftLMControlTests",
      swiftSettings: strictConcurrency
    ),
    .testTarget(
      name: "SwiftLMTUITests",
      dependencies: [
        "SwiftLMTUI",
        .product(name: "Nimble", package: "Nimble"),
      ],
      path: "Tests/SwiftLMTUITests",
      exclude: ["Snapshots"],
      swiftSettings: strictConcurrency
    ),
    .testTarget(
      name: "LMDServeTests",
      dependencies: [
        "LMDServeSupport",
        "SwiftLMCore",
        "SwiftLMRuntime",
        "SwiftLMHostProtocol",
        .product(name: "Nimble", package: "Nimble"),
      ],
      path: "Tests/LMDServeTests",
      swiftSettings: strictConcurrency
    ),
    .testTarget(
      name: "SwiftLMHostProtocolTests",
      dependencies: [
        "SwiftLMHostProtocol",
        .product(name: "Nimble", package: "Nimble"),
      ],
      path: "Tests/SwiftLMHostProtocolTests",
      swiftSettings: strictConcurrency
    ),
    .testTarget(
      name: "LMDModelHostTests",
      dependencies: [
        "lmd-model-host",
        .product(name: "Nimble", package: "Nimble"),
      ],
      path: "Tests/LMDModelHostTests",
      swiftSettings: strictConcurrency
    ),
    .testTarget(
      name: "IntegrationTests",
      dependencies: [
        "SwiftLMControl",
        "SwiftLMCore",
        "SwiftLMRuntime",
        "SwiftLMHostProtocol",
        .product(name: "Nimble", package: "Nimble"),
      ],
      path: "Tests/IntegrationTests",
      swiftSettings: strictConcurrency
    ),
  ]
)
