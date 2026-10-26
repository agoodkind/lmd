//
//  MaintenanceTestExecutable.swift
//  LMDMaintenanceTests
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-10-25.
//  Copyright © 2026, all rights reserved.
//

import Foundation
import SwiftMkCore

enum MaintenanceTestExecutable {
  static func locate(for testType: AnyClass) throws -> URL {
    Output.debug("maintenance_test.executable.locate")
    var directory = Bundle(for: testType).bundleURL
    while directory.path != "/" {
      let candidate = directory.appendingPathComponent("lmd-maintenance")
      if FileManager.default.isExecutableFile(atPath: candidate.path) {
        return candidate
      }
      directory.deleteLastPathComponent()
    }
    throw CocoaError(
      .fileNoSuchFile,
      userInfo: [NSLocalizedDescriptionKey: "Build lmd-maintenance beside the test runner."])
  }
}
