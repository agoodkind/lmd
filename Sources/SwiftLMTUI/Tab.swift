//
//  Tab.swift
//  SwiftLMTUI
//
//  Created by Alex Goodkind <alex@goodkind.io> on 2026-04-18.
//  Copyright © 2026
//
//  Tab protocol for multi-screen TUIs. The plan in plan/GENERALIZATION.md
//  introduces tabs for monitor / library / chat / bench / events. Each
//  conforms to this protocol. The top-level TUI router holds a list of
//  tabs, renders the active one, and forwards input events.
//

import AppLogger
import Foundation

private let log = AppLogger.logger(category: "TabRouter")

// MARK: - Input

/// Decoded keyboard or mouse event the tab can react to.
public enum TabInput: Sendable {
  case key(KeyEvent)
  case mouseWheel(SGRMouseEvent)
  case mouseClick(SGRMouseEvent)
  case resized(rows: Int, cols: Int)
  case tick  // 500 ms tick from the render loop
}

/// What the tab wants the router to do after handling an input.
public enum TabAction: Sendable {
  /// No side effect; just redraw.
  case none
  /// Switch to another tab by label.
  case switchTo(tab: String)
  /// Exit the TUI entirely.
  case quit
  /// Tab wants to emit a side-effectful command the host should run
  /// (e.g. "preload model X"). Routers decide how to honor these.
  case command(name: String, payload: [String: String])
}

// MARK: - Rendering surface

/// Minimal draw surface a tab writes into. Implementations buffer text
/// at absolute row/column positions so the router can composite tabs
/// together without them stepping on each other.
public protocol ScreenBuffer: AnyObject {
  /// Terminal rows.
  var rows: Int { get }
  /// Terminal cols.
  var cols: Int { get }
  /// Write a string anchored at a 1-based row.
  func put(row: Int, _ text: String)
}

/// Reference `ScreenBuffer` that collects rows and flushes through
/// `Screen.writeRow` at the end of a frame. Tests can use a trivial
/// in-memory implementation.
public final class BufferedScreen: ScreenBuffer {
  public let rows: Int
  public let cols: Int
  public private(set) var rowsPainted: [Int: String] = [:]

  public init(rows: Int, cols: Int) {
    self.rows = rows
    self.cols = cols
  }

  public func put(row: Int, _ text: String) {
    rowsPainted[row] = text
  }

  public func reset() {
    rowsPainted.removeAll(keepingCapacity: true)
  }
}

// MARK: - Tab

/// A full-screen panel managed by the TUI router.
///
/// Tabs are pure-ish: they read world state, render into a buffer, and
/// return an action in response to input. Side effects (HTTP calls,
/// subprocess spawns) happen outside the tab via the `.command` action
/// or through injected dependencies the tab was constructed with.
public protocol Tab: AnyObject {
  /// Short identifier used by the router's tab bar and by `switchTo`.
  var label: String { get }

  /// Human-readable title shown in the tab bar.
  var title: String { get }

  /// Paint one frame into the buffer. Writes only the rows this tab
  /// owns (i.e. excluding the top tab bar and bottom keybind bar).
  func render(into buffer: ScreenBuffer, contentRows: ClosedRange<Int>)

  /// Handle one decoded input event.
  func handle(_ input: TabInput) -> TabAction
}

// MARK: - Router

/// Holds the active-tab stack and dispatches input. Tests drive this
/// with a `BufferedScreen` and synthetic `TabInput`s.
public final class TabRouter {
  public private(set) var tabs: [Tab]
  public private(set) var activeIndex: Int = 0
  public var activeTab: Tab? { tabs.indices.contains(activeIndex) ? tabs[activeIndex] : nil }

  public init(tabs: [Tab]) {
    self.tabs = tabs
  }

  /// Select the tab at `index`, clamped to the valid range. Host loops
  /// use this when the user presses number keys or Tab.
  public func setActive(index: Int) {
    guard !tabs.isEmpty else { return }
    let clamped = max(0, min(index, tabs.count - 1))
    log.debug("tab.activated index=\(clamped, privacy: .public) label=\(self.tabs[clamped].label, privacy: .public)")
    activeIndex = clamped
  }

  /// Number keys 1-9 select the corresponding tab. `Tab` (keycode 9) cycles.
  public func handle(_ input: TabInput) -> TabAction {
    guard let active = activeTab else { return .none }
    let action = active.handle(input)
    switch action {
    case .switchTo(let label):
      if let idx = tabs.firstIndex(where: { $0.label == label }) {
        activeIndex = idx
      }
      return .none
    default:
      return action
    }
  }

  public func render(into buffer: ScreenBuffer, contentRows: ClosedRange<Int>) {
    activeTab?.render(into: buffer, contentRows: contentRows)
  }

  /// Tab bar rendered by the host. Format: ` monitor · library · chat `.
  /// Active tab is styled; others are dim.
  public func tabBar(active: String, dim: String, reset: String) -> String {
    tabs.enumerated().map { index, tab in
      let chunk = " \(tab.title) "
      return index == activeIndex ? "\(active)\(chunk)\(reset)" : "\(dim)\(chunk)\(reset)"
    }.joined(separator: " · ")
  }
}
