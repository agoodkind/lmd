//
//  Project.swift
//  lmd
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-05-10.
//  Copyright © 2026, all rights reserved.
//

import ProjectDescription

/// The editor indent and tab width applied to the generated project's text settings.
private let editorTextWidth: UInt = 2

let swiftSixSettings: Settings = .settings(
  base: [
    "SWIFT_VERSION": "6.0",
    "OTHER_SWIFT_FLAGS": [
      "$(inherited)",
      "-enable-upcoming-feature",
      "StrictConcurrency",
    ],
  ]
)

let swiftFiveSettings: Settings = .settings(
  base: [
    "SWIFT_VERSION": "5.0"
  ]
)

let lmdServeSettings: Settings = .settings(
  base: [
    "SWIFT_VERSION": "6.0",
    "PRODUCT_MODULE_NAME": "lmd_serve",
  ]
)

let deploymentTargets: DeploymentTargets = .macOS("14.0")

func frameworkTarget(
  _ name: String,
  dependencies: [TargetDependency] = []
) -> Target {
  .target(
    name: name,
    destinations: .macOS,
    product: .staticFramework,
    bundleId: "io.goodkind.lmd.\(name)",
    deploymentTargets: deploymentTargets,
    sources: ["Sources/\(name)/**/*.swift"],
    dependencies: dependencies,
    settings: swiftSixSettings
  )
}

func commandLineTarget(
  _ name: String,
  bundleIdSuffix: String,
  dependencies: [TargetDependency],
  settings: Settings? = nil
) -> Target {
  .target(
    name: name,
    destinations: .macOS,
    product: .commandLineTool,
    bundleId: "io.goodkind.lmd.\(bundleIdSuffix)",
    deploymentTargets: deploymentTargets,
    sources: ["Sources/\(name)/**/*.swift"],
    dependencies: dependencies,
    settings: settings
  )
}

func testTarget(
  _ name: String,
  dependencies: [TargetDependency]
) -> Target {
  .target(
    name: name,
    destinations: .macOS,
    product: .unitTests,
    bundleId: "io.goodkind.lmd.\(name)",
    deploymentTargets: deploymentTargets,
    sources: ["Tests/\(name)/**/*.swift"],
    dependencies: dependencies,
    settings: swiftSixSettings
  )
}

let commandLineToolNames = [
  "lmd",
  "lmd-serve",
]

let testTargetNames = [
  "AppLoggerTests",
  "SwiftLMCoreTests",
  "SwiftLMBackendTests",
  "SwiftLMEmbedTests",
  "SwiftLMMonitorTests",
  "LMDBenchToolTests",
  "SwiftLMMetricsTests",
  "SwiftLMRuntimeTests",
  "SwiftLMControlTests",
  "SwiftLMTUITests",
  "LMDServeTests",
  "IntegrationTests",
]

let commandLineToolSchemes = commandLineToolNames.map { name in
  Scheme.scheme(
    name: name,
    buildAction: .buildAction(targets: [.target(name)]),
    runAction: .runAction(
      executable: .executable(.target(name)),
      customWorkingDirectory: .relativeToRoot(".")
    )
  )
}

let testScheme = Scheme.scheme(
  name: "LMDTests",
  buildAction: .buildAction(targets: testTargetNames.map { .target($0) }),
  testAction: .targets(testTargetNames.map { .testableTarget(target: .target($0)) })
)

let project = Project(
  name: "LMD",
  organizationName: "Goodkind",
  options: .options(
    automaticSchemesOptions: .disabled,
    textSettings: .textSettings(indentWidth: editorTextWidth, tabWidth: editorTextWidth)
  ),
  targets: [
    frameworkTarget(
      "AppLogger",
      dependencies: [.external(name: "Logging")]
    ),
    frameworkTarget(
      "SwiftLMCore",
      dependencies: []
    ),
    frameworkTarget(
      "SwiftLMMetrics",
      dependencies: [
        .external(name: "Metrics"),
        .external(name: "Tracing"),
      ]
    ),
    frameworkTarget(
      "SwiftLMHostProtocol",
      dependencies: []
    ),
    frameworkTarget(
      "SwiftLMTrace",
      dependencies: [
        .target(name: "AppLogger"),
        .target(name: "SwiftLMMetrics"),
        .external(name: "MLXLMCommon"),
      ]
    ),
    frameworkTarget(
      "SwiftLMBackend",
      dependencies: [
        .target(name: "AppLogger"),
        .target(name: "SwiftLMCore"),
        .external(name: "MLXLMCommon"),
        .external(name: "MLXVLM"),
        .external(name: "MLXHuggingFace"),
        .external(name: "Tokenizers"),
      ]
    ),
    frameworkTarget(
      "SwiftLMEmbed",
      dependencies: [
        .target(name: "AppLogger"),
        .target(name: "SwiftLMCore"),
        .target(name: "SwiftLMBackend"),
        .target(name: "SwiftLMTrace"),
        .target(name: "SwiftLMMetrics"),
        .external(name: "MLXEmbedders"),
        .external(name: "MLXLMCommon"),
        .external(name: "MLXHuggingFace"),
        .external(name: "Tokenizers"),
      ]
    ),
    frameworkTarget(
      "SwiftLMRuntime",
      dependencies: [
        .target(name: "AppLogger"),
        .target(name: "SwiftLMCore"),
        .target(name: "SwiftLMTrace"),
        .target(name: "SwiftLMHostProtocol"),
        .external(name: "SMCFanXPCClient"),
      ]
    ),
    frameworkTarget(
      "SwiftLMMonitor",
      dependencies: [
        .target(name: "AppLogger")
      ]
    ),
    frameworkTarget(
      "SwiftLMTUI",
      dependencies: [
        .target(name: "AppLogger")
      ]
    ),
    frameworkTarget(
      "SwiftLMControl",
      dependencies: [
        .target(name: "AppLogger"),
        .target(name: "SwiftLMCore"),
        .target(name: "SwiftLMRuntime"),
      ]
    ),
    .target(
      name: "LMDTUIHost",
      destinations: .macOS,
      product: .staticFramework,
      bundleId: "io.goodkind.lmd.LMDTUIHost",
      deploymentTargets: deploymentTargets,
      sources: ["Sources/lmd-tui/**/*.swift"],
      dependencies: [
        .target(name: "AppLogger"),
        .target(name: "SwiftLMCore"),
        .target(name: "SwiftLMRuntime"),
        .target(name: "SwiftLMTUI"),
        .target(name: "SwiftLMControl"),
      ],
      settings: swiftFiveSettings
    ),
    .target(
      name: "LMDBenchTool",
      destinations: .macOS,
      product: .staticFramework,
      bundleId: "io.goodkind.lmd.LMDBenchTool",
      deploymentTargets: deploymentTargets,
      sources: ["Sources/lmd-bench/**/*.swift"],
      dependencies: [
        .target(name: "AppLogger"),
        .target(name: "SwiftLMBackend"),
        .target(name: "SwiftLMRuntime"),
        .target(name: "SwiftLMMonitor"),
      ],
      settings: swiftFiveSettings
    ),
    .target(
      name: "LMDQATool",
      destinations: .macOS,
      product: .staticFramework,
      bundleId: "io.goodkind.lmd.LMDQATool",
      deploymentTargets: deploymentTargets,
      sources: ["Sources/lmd-qa/**/*.swift"],
      dependencies: [
        .external(name: "SwiftTerm")
      ],
      settings: swiftFiveSettings
    ),
    frameworkTarget(
      "LMDServeSupport",
      dependencies: [
        .target(name: "AppLogger"),
        .target(name: "SwiftLMCore"),
        .target(name: "SwiftLMBackend"),
        .target(name: "SwiftLMControl"),
        .target(name: "SwiftLMRuntime"),
        .target(name: "SwiftLMTrace"),
        .target(name: "SwiftLMMetrics"),
        .target(name: "SwiftLMHostProtocol"),
        .external(name: "Hummingbird"),
        .external(name: "MLXLMCommon"),
      ]
    ),
    commandLineTarget(
      "lmd",
      bundleIdSuffix: "cli",
      dependencies: [
        .external(name: "ArgumentParser"),
        .target(name: "AppLogger"),
        .target(name: "SwiftLMCore"),
        .target(name: "SwiftLMRuntime"),
        .target(name: "SwiftLMControl"),
        .target(name: "LMDTUIHost"),
        .target(name: "LMDBenchTool"),
        .target(name: "LMDQATool"),
      ],
      settings: swiftSixSettings
    ),
    commandLineTarget(
      "lmd-serve",
      bundleIdSuffix: "serve",
      dependencies: [
        .target(name: "AppLogger"),
        .target(name: "SwiftLMCore"),
        .target(name: "SwiftLMEmbed"),
        .target(name: "SwiftLMRuntime"),
        .target(name: "SwiftLMMonitor"),
        .target(name: "SwiftLMControl"),
        .target(name: "SwiftLMMetrics"),
        .target(name: "SwiftLMTrace"),
        .target(name: "SwiftLMHostProtocol"),
        .target(name: "LMDServeSupport"),
        .external(name: "Hummingbird"),
        .external(name: "NIOTransportServices"),
        .external(name: "HuggingFace"),
      ],
      settings: lmdServeSettings
    ),
    testTarget(
      "AppLoggerTests",
      dependencies: [.target(name: "AppLogger")]
    ),
    testTarget(
      "SwiftLMCoreTests",
      dependencies: [.target(name: "SwiftLMCore")]
    ),
    testTarget(
      "SwiftLMBackendTests",
      dependencies: [
        .target(name: "SwiftLMBackend"),
        .target(name: "SwiftLMCore"),
        .external(name: "MLXLMCommon"),
      ]
    ),
    testTarget(
      "SwiftLMEmbedTests",
      dependencies: [
        .target(name: "SwiftLMEmbed"),
        .target(name: "SwiftLMCore"),
        .external(name: "MLX"),
      ]
    ),
    testTarget(
      "SwiftLMMonitorTests",
      dependencies: [.target(name: "SwiftLMMonitor")]
    ),
    testTarget(
      "LMDBenchToolTests",
      dependencies: [
        .target(name: "LMDBenchTool")
      ]
    ),
    testTarget(
      "SwiftLMMetricsTests",
      dependencies: [
        .target(name: "SwiftLMMetrics"),
        .external(name: "Metrics"),
      ]
    ),
    testTarget(
      "SwiftLMRuntimeTests",
      dependencies: [
        .target(name: "SwiftLMRuntime"),
        .target(name: "SwiftLMCore"),
        .target(name: "SwiftLMHostProtocol"),
        .target(name: "SwiftLMTrace"),
      ]
    ),
    testTarget(
      "SwiftLMControlTests",
      dependencies: [
        .target(name: "SwiftLMControl"),
        .target(name: "SwiftLMCore"),
        .target(name: "SwiftLMRuntime"),
      ]
    ),
    testTarget(
      "SwiftLMTUITests",
      dependencies: [.target(name: "SwiftLMTUI")]
    ),
    testTarget(
      "LMDServeTests",
      dependencies: [
        .target(name: "LMDServeSupport"),
        .target(name: "SwiftLMCore"),
      ]
    ),
    testTarget(
      "IntegrationTests",
      dependencies: [
        .target(name: "SwiftLMControl"),
        .target(name: "SwiftLMCore"),
        .target(name: "SwiftLMRuntime"),
      ]
    ),
  ],
  schemes: commandLineToolSchemes + [testScheme]
)
