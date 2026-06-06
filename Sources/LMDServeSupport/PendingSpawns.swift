//
//  PendingSpawns.swift
//  LMDServeSupport
//
//  Maps a per-spawn token to the model id of a child the broker just launched.
//  The host listener claims the token when the child dials in with `hello`,
//  binding the accepted session to the matching model. Single-use: a token is
//  removed when claimed, so a replayed or duplicate dial-in finds nothing.
//

import Foundation

public actor PendingSpawns {
  private var byToken: [String: String] = [:]

  public init() {}

  public func register(token: String, modelID: String) {
    byToken[token] = modelID
  }

  /// Returns the model id for a token and removes it. Returns nil for an
  /// unknown or already-claimed token.
  public func claim(token: String) -> String? {
    byToken.removeValue(forKey: token)
  }

  public func drop(token: String) {
    byToken.removeValue(forKey: token)
  }
}
