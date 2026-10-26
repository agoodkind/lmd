//
//  DependencyVersionsLock.swift
//  lmd-maintenance
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-10-25.
//  Copyright © 2026, all rights reserved.
//

import Foundation
import SwiftMkCore

// MARK: - Resolved package metadata

struct DependencyVersionsLock: Codable {
  var pins: [Pin]
  let version: Int
  let originHash: String?

  struct Pin: Codable, Equatable {
    let identity: String
    let kind: String
    let location: String
    let state: [String: String]

    private enum CodingKeys: String, CodingKey {
      case identity, kind, location, state
    }

    init(from decoder: Decoder) throws {
      let fields = try decoder.container(keyedBy: DependencyVersionsLockField.self)
      try requireMaintenanceCondition(
        Set(fields.allKeys.map(\.stringValue)) == Set(["identity", "kind", "location", "state"]),
        "Unexpected dependency lock pin fields")
      let container = try decoder.container(keyedBy: CodingKeys.self)
      identity = try container.decode(String.self, forKey: .identity)
      kind = try container.decode(String.self, forKey: .kind)
      location = try container.decode(String.self, forKey: .location)
      state = try container.decode([String: String].self, forKey: .state)
    }
  }

  init(_ path: URL) throws {
    Output.debug("versions.lock.read path=\(path.path)")
    self = try JSONDecoder().decode(Self.self, from: Data(contentsOf: path))
  }

  func otherPins(excluding identities: [String]) throws -> [String: Pin] {
    var result: [String: Pin] = [:]
    var seen = Set<String>()
    for pin in pins {
      try requireMaintenanceCondition(
        seen.insert(pin.identity).inserted, "Duplicate dependency identity: \(pin.identity)")
      if !identities.contains(pin.identity) { result[pin.identity] = pin }
    }
    return result
  }

  func revision(_ identity: String) throws -> String {
    let matches = pins.filter { $0.identity == identity }
    try requireMaintenanceCondition(
      matches.count == 1, "Expected one resolved dependency: \(identity)")
    guard let revision = matches[0].state["revision"] else {
      throw MaintenanceError.failure("Missing resolved revision: \(identity)")
    }
    return revision
  }
}

// MARK: - Complete pin field validation

private struct DependencyVersionsLockField: CodingKey {
  let stringValue: String
  let intValue: Int?

  init?(stringValue: String) {
    self.stringValue = stringValue
    intValue = nil
  }
  init?(intValue: Int) {
    stringValue = String(intValue)
    self.intValue = intValue
  }
}
