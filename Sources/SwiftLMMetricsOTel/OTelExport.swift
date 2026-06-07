//
//  OTelExport.swift
//  SwiftLMMetricsOTel
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-06-07.
//  Copyright © 2026, all rights reserved.
//
//  The OTLP export arm, kept in its own target so swift-otel's transitive tree
//  (grpc-swift, swift-nio, swift-protobuf, the async-http-client C targets)
//  stays out of the core metrics plane and the Tuist project graph. Only the
//  SwiftPM-built lmd-serve and lmd-model-host link this; callers guard the
//  import with #if canImport(SwiftLMMetricsOTel) so the Tuist build (which omits
//  this target) compiles without it.
//
//  When OTEL_EXPORTER_OTLP_ENDPOINT is set, installExportIfEnabled builds
//  swift-otel's metrics factory (returned for the caller to add to the
//  SwiftLMMetrics multiplex), installs the tracer into InstrumentationSystem,
//  and returns the exporter services so the caller runs and flushes them in a
//  ServiceGroup. swift-otel honors the standard OTEL_* environment variables
//  (endpoint, protocol, sampler) on top of the resource identity set here.
//

import CoreMetrics
import Foundation
import Instrumentation
import Logging
import OTel
import ServiceLifecycle

public enum SwiftLMMetricsOTel {
  /// Owns the running OTLP exporter services in a ServiceGroup. The group runs
  /// in a detached task for the life of the process; `shutdownAndFlush` triggers
  /// graceful shutdown so the last batch of metrics and spans is exported before
  /// a short-lived helper calls `exit`.
  public final class ExportRunner: @unchecked Sendable {
    private let group: ServiceGroup
    private let runTask: Task<Void, Never>

    init(services: [any Service], logger: Logger) {
      let group = ServiceGroup(configuration: .init(services: services, logger: logger))
      self.group = group
      self.runTask = Task { try? await group.run() }
    }

    /// Trigger graceful shutdown and await the exporters' final flush. Safe to
    /// call once before process exit.
    public func shutdownAndFlush() async {
      await group.triggerGracefulShutdown()
      await runTask.value
    }
  }

  /// Result of installing the OTLP export arm. `factory` is nil when export is
  /// disabled (no endpoint) or misconfigured; pass it to
  /// `SwiftLMMetrics.bootstrap(extraFactories:)`. `runner` owns the running
  /// exporter services; a long-lived broker keeps it alive, and a short-lived
  /// helper calls `runner.shutdownAndFlush()` before `exit`.
  public struct Installation: Sendable {
    public let factory: (any CoreMetrics.MetricsFactory)?
    public let runner: ExportRunner?

    public static let disabled = Installation(factory: nil, runner: nil)
  }

  /// Build the OTLP metrics factory and install the tracer, gated on
  /// OTEL_EXPORTER_OTLP_ENDPOINT. Stamps the process identity as resource
  /// attributes: `service.name` is the process role and `service.instance.id`
  /// is the per-helper source_id, so the collector separates each process.
  ///
  /// Best effort: a missing endpoint returns `.disabled`, and a configuration
  /// error is swallowed so a bad endpoint never takes down the process. The
  /// in-process SnapshotSink plane keeps working regardless.
  public static func installExportIfEnabled(
    serviceName: String,
    sourceID: String
  ) -> Installation {
    guard ProcessInfo.processInfo.environment["OTEL_EXPORTER_OTLP_ENDPOINT"] != nil else {
      return .disabled
    }
    do {
      var configuration = OTel.Configuration.default
      configuration.serviceName = serviceName
      configuration.resourceAttributes["service.instance.id"] = sourceID
      // lmd logging stays on os_log/AppLogger; do not export otel logs.
      configuration.logs.enabled = false

      let metricsBackend = try OTel.makeMetricsBackend(configuration: configuration)
      let tracingBackend = try OTel.makeTracingBackend(configuration: configuration)

      InstrumentationSystem.bootstrap(tracingBackend.factory)

      let services: [any Service] = [metricsBackend.service, tracingBackend.service]
      let runner = ExportRunner(
        services: services,
        logger: Logger(label: "lmd.otel.\(serviceName)")
      )
      return Installation(factory: metricsBackend.factory, runner: runner)
    } catch {
      return .disabled
    }
  }
}
