//
//  LibraryTabTests.swift
//  SwiftLMTUITests
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-04-18.
//  Copyright © 2026, all rights reserved.
//

import Nimble
import XCTest

@testable import SwiftLMTUI

final class LibraryTabTests: XCTestCase {
  private func fixtureEntries() -> [LibraryEntry] {
    [
      LibraryEntry(
        id: "a", displayName: "Alpha", slug: "test/alpha",
        sizeGB: 5, isLoaded: true, inFlightRequests: 0
      ),
      LibraryEntry(
        id: "b", displayName: "Beta", slug: "test/beta",
        sizeGB: 10, isLoaded: false, inFlightRequests: 0
      ),
      LibraryEntry(
        id: "c", displayName: "Gamma", slug: "test/gamma",
        sizeGB: 20, isLoaded: true, inFlightRequests: 2
      ),
    ]
  }

  func testJKNavigates() {
    let tab = LibraryTab()
    tab.entries = fixtureEntries()
    expect(tab.selection) == 0
    _ = tab.handle(.key(.scrollDown))
    expect(tab.selection) == 1
    _ = tab.handle(.key(.scrollDown))
    expect(tab.selection) == 2
    _ = tab.handle(.key(.scrollDown))  // clamp at last
    expect(tab.selection) == 2
    _ = tab.handle(.key(.scrollUp))
    expect(tab.selection) == 1
  }

  func testLoadCharProducesCommand() {
    let tab = LibraryTab()
    tab.entries = fixtureEntries()
    _ = tab.handle(.key(.scrollDown))  // selection now 1 = Beta
    let action = tab.handleChar("l")
    if case .command(let name, let payload) = action {
      expect(name) == "preload"
      expect(payload["model"]) == "b"
    } else {
      fail("expected preload command, got \(action)")
    }
  }

  func testUnloadCharProducesCommand() {
    let tab = LibraryTab()
    tab.entries = fixtureEntries()
    let action = tab.handleChar("u")
    if case .command(let name, _) = action {
      expect(name) == "unload"
    } else {
      fail("expected unload, got \(action)")
    }
  }

  func testRenderIncludesLoadedAndIdleMarkers() {
    let tab = LibraryTab()
    tab.entries = fixtureEntries()
    let buf = BufferedScreen(rows: 30, cols: 160)
    tab.render(into: buf, contentRows: 1...25)
    let combined = buf.rowsPainted.values.joined(separator: "\n")
    expect(combined.contains("loaded")) == true
    expect(combined.contains("idle")) == true
    expect(combined.contains("busy")) == true
    expect(combined.contains("Alpha")) == true
    expect(combined.contains("Beta")) == true
    expect(combined.contains("Gamma")) == true
  }

  func testEmptyEntriesShowsMessage() {
    let tab = LibraryTab()
    let buf = BufferedScreen(rows: 10, cols: 80)
    tab.render(into: buf, contentRows: 1...8)
    let combined = buf.rowsPainted.values.joined(separator: "\n")
    expect(combined.contains("no models found")) == true
  }
}
