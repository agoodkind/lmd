// swift-tools-version: 6.1
//
//  Package.swift
//  lmd
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-05-10.
//  Copyright © 2026, all rights reserved.
//

import PackageDescription

#if TUIST
  import struct ProjectDescription.PackageSettings

  let packageSettings = PackageSettings(
    productTypes: [
      "SwiftTerm": .framework
    ],
    baseProductType: .staticFramework,
    targetSettings: [
      "SwiftTerm": [
        "EXCLUDED_SOURCE_FILE_NAMES": "Shaders.metal"
      ]
    ]
  )
#endif

let package = Package(
  name: "LMDDependencies",
  platforms: [.macOS(.v14)],
  dependencies: [
    .package(url: "https://github.com/apple/swift-argument-parser", from: "1.7.0"),
    .package(url: "https://github.com/hummingbird-project/hummingbird", from: "2.22.0"),
    .package(url: "https://github.com/apple/swift-nio-transport-services.git", from: "1.23.0"),
    .package(url: "https://github.com/apple/swift-log.git", from: "1.12.0"),
    .package(url: "https://github.com/apple/swift-metrics.git", from: "2.5.0"),
    .package(url: "https://github.com/apple/swift-distributed-tracing.git", from: "1.1.0"),
    .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", from: "1.2.0"),
    .package(
      url: "https://github.com/agoodkind/mlx-swift-lm.git",
      revision: "9d77504276de8113b1f5be3a519c2b9d35938ebc"),
    .package(url: "https://github.com/agoodkind/mlx-swift.git", branch: "main"),
    .package(url: "https://github.com/huggingface/swift-huggingface.git", from: "0.9.0"),
    .package(url: "https://github.com/huggingface/swift-transformers.git", from: "1.3.2"),
    .package(url: "https://github.com/agoodkind/macos-smc-fan.git", branch: "main"),
  ]
)
