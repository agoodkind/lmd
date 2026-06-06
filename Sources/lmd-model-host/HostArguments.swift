//
//  HostArguments.swift
//  lmd-model-host
//
//  Parses the broker-supplied argv for a model host child. The spawn token is
//  NOT here: it arrives on stdin, a private parent-to-child pipe.
//

import Foundation
import SwiftLMHostProtocol

struct HostArguments: Equatable {
  let modelPath: String
  let kind: BackendKind
  let hostService: String

  /// Parse `--model <path> --kind <chat|embedding|video> --host-service <name>`.
  /// Returns nil when any field is missing or the kind is unrecognized.
  static func parse(_ argv: [String]) -> HostArguments? {
    var model: String?
    var kindRaw: String?
    var service: String?
    var index = 0
    while index + 1 < argv.count {
      switch argv[index] {
      case "--model": model = argv[index + 1]
      case "--kind": kindRaw = argv[index + 1]
      case "--host-service": service = argv[index + 1]
      default: break
      }
      index += 2
    }
    guard let model, let kindRaw, let service, let kind = BackendKind(rawValue: kindRaw) else {
      return nil
    }
    return HostArguments(modelPath: model, kind: kind, hostService: service)
  }
}
