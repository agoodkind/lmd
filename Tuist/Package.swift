// swift-tools-version: 6.1

import PackageDescription

#if TUIST
  import struct ProjectDescription.PackageSettings

  let packageSettings = PackageSettings(
    productTypes: [
      "SwiftTerm": .framework,
    ],
    baseProductType: .staticFramework,
    targetSettings: [
      "SwiftTerm": [
        "EXCLUDED_SOURCE_FILE_NAMES": "Shaders.metal",
      ],
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
    .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", from: "1.2.0"),
    .package(url: "https://github.com/john-rocky/mlx-swift-lm.git", branch: "feat/gemma4-video"),
    .package(url: "https://github.com/ml-explore/mlx-swift", .upToNextMinor(from: "0.31.3")),
    .package(url: "https://github.com/huggingface/swift-huggingface.git", from: "0.9.0"),
    .package(url: "https://github.com/huggingface/swift-transformers.git", from: "1.3.2"),
    .package(url: "https://github.com/agoodkind/macos-smc-fan.git", branch: "main"),
  ]
)
