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
import OTel
import ServiceLifecycle

public enum SwiftLMMetricsOTel {
  /// Result of installing the OTLP export arm. `factory` is nil when export is
  /// disabled (no endpoint) or misconfigured; pass it to
  /// `SwiftLMMetrics.bootstrap(extraFactories:)`. `services` are the exporter
  /// background services the caller must run in a ServiceGroup and shut down
  /// before process exit so the final batch of metrics and spans flushes.
  public struct Installation: Sendable {
    public let factory: (any CoreMetrics.MetricsFactory)?
    public let services: [any Service]

    public static let disabled = Installation(factory: nil, services: [])
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
      return Installation(factory: metricsBackend.factory, services: services)
    } catch {
      return .disabled
    }
  }
}
