//
//  MaintenanceError.swift
//  lmd-maintenance
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-10-25.
//  Copyright © 2026, all rights reserved.
//

import Foundation

#if canImport(CryptoKit)
  import CryptoKit
#else
  import Crypto
#endif

// MARK: - MaintenanceError

enum MaintenanceError: Error, CustomStringConvertible {
  case failure(String)

  var description: String {
    switch self {
    case .failure(let message):
      return message
    }
  }
}

func requireMaintenanceCondition(_ condition: Bool, _ message: String) throws {
  guard condition else {
    throw MaintenanceError.failure(message)
  }
}

func maintenanceSHA256(_ data: Data) -> String {
  SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}
