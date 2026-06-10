//
//  TabRouterTests.swift
//  SwiftLMTUITests
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-04-18.
//  Copyright © 2026, all rights reserved.
//

import Nimble
import XCTest

@testable import SwiftLMTUI

private final class StubTab: Tab {
  let label: String
  let title: String
  var seenInputs: [TabInput] = []
  var renderCalls = 0
  var nextAction: TabAction = .none

  init(label: String, title: String) {
    self.label = label
    self.title = title
  }

  func render(into buffer: ScreenBuffer, contentRows: ClosedRange<Int>) {
    renderCalls += 1
    buffer.put(row: contentRows.lowerBound, "\(label)-rendered")
  }

  func handle(_ input: TabInput) -> TabAction {
    seenInputs.append(input)
    return nextAction
  }
}

final class TabRouterTests: XCTestCase {
  func testInitialActiveIsFirstTab() {
    let a = StubTab(label: "a", title: "A")
    let b = StubTab(label: "b", title: "B")
    let router = TabRouter(tabs: [a, b])
    expect(router.activeTab?.label) == "a"
  }

  func testRenderFanoutsToActiveOnly() {
    let a = StubTab(label: "a", title: "A")
    let b = StubTab(label: "b", title: "B")
    let router = TabRouter(tabs: [a, b])
    let buf = BufferedScreen(rows: 20, cols: 80)
    router.render(into: buf, contentRows: 3...18)
    expect(a.renderCalls) == 1
    expect(b.renderCalls) == 0
    expect(buf.rowsPainted[3]) == "a-rendered"
  }

  func testSwitchActionChangesActiveTab() {
    let a = StubTab(label: "a", title: "A")
    let b = StubTab(label: "b", title: "B")
    a.nextAction = .switchTo(tab: "b")
    let router = TabRouter(tabs: [a, b])
    _ = router.handle(.key(.scrollDown))
    expect(router.activeTab?.label) == "b"
  }

  func testSwitchToMissingTabIsNoOp() {
    let a = StubTab(label: "a", title: "A")
    a.nextAction = .switchTo(tab: "ghost")
    let router = TabRouter(tabs: [a])
    _ = router.handle(.key(.scrollDown))
    expect(router.activeTab?.label) == "a"
  }

  func testInputForwardedToActiveTab() {
    let a = StubTab(label: "a", title: "A")
    let b = StubTab(label: "b", title: "B")
    let router = TabRouter(tabs: [a, b])
    _ = router.handle(.key(.scrollDown))
    _ = router.handle(.tick)
    expect(a.seenInputs.count) == 2
    expect(b.seenInputs.isEmpty) == true
  }

  func testQuitActionPassesThroughToCaller() {
    let a = StubTab(label: "a", title: "A")
    a.nextAction = .quit
    let router = TabRouter(tabs: [a])
    let action = router.handle(.key(.quit))
    if case .quit = action {} else { fail("expected .quit, got \(action)") }
  }
}
