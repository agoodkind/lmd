import ProjectDescription

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
    "SWIFT_VERSION": "5.0",
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
  "lmd-tui",
  "lmd-bench",
  "lmd-qa",
]

let testTargetNames = [
  "AppLoggerTests",
  "SwiftLMCoreTests",
  "SwiftLMBackendTests",
  "SwiftLMMonitorTests",
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
    textSettings: .textSettings(indentWidth: 2, tabWidth: 2)
  ),
  targets: [
    frameworkTarget(
      "AppLogger",
      dependencies: [.external(name: "Logging")]
    ),
    frameworkTarget(
      "SwiftLMCore",
      dependencies: [.target(name: "AppLogger")]
    ),
    frameworkTarget(
      "SwiftLMBackend",
      dependencies: [
        .target(name: "AppLogger"),
        .target(name: "SwiftLMCore"),
        .external(name: "MLXLMCommon"),
        .external(name: "MLXVLM"),
      ]
    ),
    frameworkTarget(
      "SwiftLMEmbed",
      dependencies: [
        .target(name: "SwiftLMCore"),
        .target(name: "SwiftLMBackend"),
        .external(name: "MLXEmbedders"),
      ]
    ),
    frameworkTarget(
      "SwiftLMRuntime",
      dependencies: [
        .target(name: "AppLogger"),
        .target(name: "SwiftLMCore"),
        .target(name: "SwiftLMBackend"),
        .external(name: "SMCFanXPCClient"),
      ]
    ),
    frameworkTarget(
      "SwiftLMMonitor",
      dependencies: [
        .target(name: "AppLogger"),
        .target(name: "SwiftLMCore"),
      ]
    ),
    frameworkTarget(
    "SwiftLMTUI",
    dependencies: [
      .target(name: "AppLogger"),
      .target(name: "SwiftLMCore"),
    ]
    ),
    frameworkTarget(
    "SwiftLMControl",
    dependencies: [
      .target(name: "AppLogger"),
      .target(name: "SwiftLMRuntime"),
    ]
  ),
    frameworkTarget(
      "LMDServeSupport",
      dependencies: [
        .target(name: "AppLogger"),
        .target(name: "SwiftLMCore"),
        .target(name: "SwiftLMBackend"),
        .external(name: "Hummingbird"),
      ]
    ),
    commandLineTarget(
      "lmd",
      bundleIdSuffix: "cli",
      dependencies: [
        .target(name: "AppLogger"),
        .target(name: "SwiftLMCore"),
        .target(name: "SwiftLMRuntime"),
        .target(name: "SwiftLMControl"),
      ],
      settings: swiftSixSettings
    ),
    commandLineTarget(
      "lmd-serve",
      bundleIdSuffix: "serve",
      dependencies: [
        .target(name: "AppLogger"),
        .target(name: "SwiftLMCore"),
        .target(name: "SwiftLMBackend"),
        .target(name: "SwiftLMEmbed"),
        .target(name: "SwiftLMRuntime"),
        .target(name: "SwiftLMMonitor"),
        .target(name: "SwiftLMControl"),
        .target(name: "LMDServeSupport"),
        .external(name: "Hummingbird"),
        .external(name: "NIOTransportServices"),
        .external(name: "HuggingFace"),
      ],
      settings: lmdServeSettings
    ),
    commandLineTarget(
      "lmd-tui",
      bundleIdSuffix: "tui",
      dependencies: [
        .target(name: "AppLogger"),
        .target(name: "SwiftLMCore"),
        .target(name: "SwiftLMRuntime"),
        .target(name: "SwiftLMTUI"),
        .target(name: "SwiftLMControl"),
      ],
      settings: swiftFiveSettings
    ),
    commandLineTarget(
      "lmd-bench",
      bundleIdSuffix: "bench",
      dependencies: [
        .target(name: "AppLogger"),
        .target(name: "SwiftLMCore"),
        .target(name: "SwiftLMBackend"),
        .target(name: "SwiftLMRuntime"),
        .target(name: "SwiftLMMonitor"),
      ],
      settings: swiftFiveSettings
    ),
    commandLineTarget(
      "lmd-qa",
      bundleIdSuffix: "qa",
      dependencies: [.external(name: "SwiftTerm")],
      settings: swiftFiveSettings
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
      dependencies: [.target(name: "SwiftLMBackend")]
    ),
    testTarget(
      "SwiftLMMonitorTests",
      dependencies: [.target(name: "SwiftLMMonitor")]
    ),
    testTarget(
      "SwiftLMRuntimeTests",
      dependencies: [
        .target(name: "SwiftLMRuntime"),
        .target(name: "SwiftLMCore"),
        .target(name: "SwiftLMBackend"),
      ]
    ),
    testTarget(
      "SwiftLMControlTests",
      dependencies: [.target(name: "SwiftLMControl")]
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
