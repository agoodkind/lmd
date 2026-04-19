//
//  EventsTabTests.swift
//  SwiftLMTUITests
//
//  Created by Alex Goodkind <alex@goodkind.io> on 2026-04-18.
//  Copyright © 2026
//

import XCTest
@testable import SwiftLMTUI

final class EventsTabTests: XCTestCase {
  func testAppendBuildsRing() {
    let tab = EventsTab()
    tab.capacity = 3
    for i in 0..<5 {
      tab.append(
        EventEntry(kind: "model.loaded", model: "m\(i)", message: "x")
      )
    }
    // Capped: only the last 3 survive.
    XCTAssertEqual(tab.entries.count, 3)
    XCTAssertEqual(tab.entries.first?.model, "m2")
    XCTAssertEqual(tab.entries.last?.model, "m4")
  }

  func testClearWipes() {
    let tab = EventsTab()
    tab.append(EventEntry(kind: "note"))
    tab.clear()
    XCTAssertTrue(tab.entries.isEmpty)
    XCTAssertEqual(tab.scrollOffset, 0)
  }

  func testScrollUpDownClamps() {
    let tab = EventsTab()
    for _ in 0..<5 {
      tab.append(EventEntry(kind: "note"))
    }
    tab.scrollUp(100)
    XCTAssertEqual(tab.scrollOffset, 4)  // count - 1
    tab.scrollDown(100)
    XCTAssertEqual(tab.scrollOffset, 0)
  }

  func testCKeyClears() {
    let tab = EventsTab()
    tab.append(EventEntry(kind: "x"))
    _ = tab.handleChar("c")
    XCTAssertTrue(tab.entries.isEmpty)
  }

  // MARK: - Snapshots

  func testEmpty() throws {
    let tab = EventsTab()
    let buffer = BufferedScreen(rows: 30, cols: 120)
    tab.render(into: buffer, contentRows: 3...28)
    try Snapshot.assertMatches(Snapshot.compose(buffer), name: "events_empty")
  }

  func testWithEntries() throws {
    let tab = EventsTab()
    // Force UTC so the formatted timestamp is deterministic regardless
    // of the machine's timezone.
    let fmt = DateFormatter()
    fmt.dateFormat = "HH:mm:ss"
    fmt.timeZone = TimeZone(identifier: "UTC")
    tab.timestampFormatter = fmt
    let base = Date(timeIntervalSince1970: 1_700_000_000)
    tab.append(EventEntry(kind: "model.loaded", model: "qwen3-30b", message: "port=5501", timestamp: base))
    tab.append(EventEntry(kind: "request.completed", model: "qwen3-30b", message: "200 OK", timestamp: base.addingTimeInterval(1)))
    tab.append(EventEntry(kind: "model.evicted", model: "qwen3-4b", message: "lru", timestamp: base.addingTimeInterval(2)))
    let buffer = BufferedScreen(rows: 30, cols: 120)
    tab.render(into: buffer, contentRows: 3...28)
    try Snapshot.assertMatches(Snapshot.compose(buffer), name: "events_three")
  }
}
