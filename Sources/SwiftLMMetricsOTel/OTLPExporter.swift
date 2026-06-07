//
//  OTLPExporter.swift
//  SwiftLMMetricsOTel
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-06-06.
//  Copyright © 2026, all rights reserved.
//
//  Broker-side payload adapter for exporting the merged metrics view.
//

import Foundation
import SwiftLMMetrics

public enum OTLPExporter {
  public static func payload(from snapshot: MergedMetricsSnapshot) throws -> Data {
    try MetricsJSON.encoder.encode(snapshot)
  }
}
