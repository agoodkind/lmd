//
//  LibraryTabTests.swift
//  SwiftLMTUITests
//
//  Created by Alex Goodkind <alex@goodkind.io> on 2026-04-18.
//  Copyright © 2026
//

import XCTest
@testable import SwiftLMTUI

final class LibraryTabTests: XCTestCase {
  private func fixtureEntries() -> [LibraryEntry] {
    return [
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
    XCTAssertEqual(tab.selection, 0)
    _ = tab.handle(.key(.scrollDown))
    XCTAssertEqual(tab.selection, 1)
    _ = tab.handle(.key(.scrollDown))
    XCTAssertEqual(tab.selection, 2)
    _ = tab.handle(.key(.scrollDown)) // clamp at last
    XCTAssertEqual(tab.selection, 2)
    _ = tab.handle(.key(.scrollUp))
    XCTAssertEqual(tab.selection, 1)
  }

  func testLoadCharProducesCommand() {
    let tab = LibraryTab()
    tab.entries = fixtureEntries()
    _ = tab.handle(.key(.scrollDown))  // selection now 1 = Beta
    let action = tab.handleChar("l")
    if case .command(let name, let payload) = action {
      XCTAssertEqual(name, "preload")
      XCTAssertEqual(payload["model"], "b")
    } else {
      XCTFail("expected preload command, got \(action)")
    }
  }

  func testUnloadCharProducesCommand() {
    let tab = LibraryTab()
    tab.entries = fixtureEntries()
    let action = tab.handleChar("u")
    if case .command(let name, _) = action {
      XCTAssertEqual(name, "unload")
    } else {
      XCTFail("expected unload, got \(action)")
    }
  }

  func testRenderIncludesLoadedAndIdleMarkers() {
    let tab = LibraryTab()
    tab.entries = fixtureEntries()
    let buf = BufferedScreen(rows: 30, cols: 160)
    tab.render(into: buf, contentRows: 1...25)
    let combined = buf.rowsPainted.values.joined(separator: "\n")
    XCTAssertTrue(combined.contains("loaded"))
    XCTAssertTrue(combined.contains("idle"))
    XCTAssertTrue(combined.contains("busy"))
    XCTAssertTrue(combined.contains("Alpha"))
    XCTAssertTrue(combined.contains("Beta"))
    XCTAssertTrue(combined.contains("Gamma"))
  }

  func testEmptyEntriesShowsMessage() {
    let tab = LibraryTab()
    let buf = BufferedScreen(rows: 10, cols: 80)
    tab.render(into: buf, contentRows: 1...8)
    let combined = buf.rowsPainted.values.joined(separator: "\n")
    XCTAssertTrue(combined.contains("no models found"))
  }
}
