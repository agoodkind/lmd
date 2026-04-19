//
//  EventsTab.swift
//  SwiftLMTUI
//
//  Created by Alex Goodkind <alex@goodkind.io> on 2026-04-18.
//  Copyright © 2026
//
//  EventsTab renders a scrolling feed of broker lifecycle events
//  (model loaded, unloaded, evicted, request proxied, etc). The host
//  subscribes to the broker's `/swiftlmd/events` SSE stream and pushes
//  each parsed event via :func:`append`. The tab keeps the last N
//  events and shows the tail that fits in the viewport.
//

import AppLogger
import Foundation

private let log = AppLogger.logger(category: "EventsTab")

// MARK: - Event shape

/// One display row. Kept free of SwiftLMRuntime dependencies so tests
/// and hosts can fake events without importing the broker.
public struct EventEntry: Sendable, Equatable {
  public let kind: String
  public let model: String?
  public let message: String
  public let timestamp: Date

  public init(kind: String, model: String? = nil, message: String = "", timestamp: Date = Date()) {
    self.kind = kind
    self.model = model
    self.message = message
    self.timestamp = timestamp
  }
}

// MARK: - EventsTab

public final class EventsTab: Tab {
  public let label = "events"
  public let title = "events"

  /// Ring of recent events; newest last. Capped at `capacity`.
  public private(set) var entries: [EventEntry] = []
  /// Scroll offset in event rows. 0 means "stick to newest".
  public private(set) var scrollOffset: Int = 0
  /// Upper bound on entries stored. Host-configurable.
  public var capacity: Int = 1024

  public init() {}

  // MARK: - Mutation API

  public func append(_ entry: EventEntry) {
    entries.append(entry)
    if entries.count > capacity {
      entries.removeFirst(entries.count - capacity)
    }
    if scrollOffset > 0 {
      // Keep viewport anchored to the same entry if the user scrolled
      // away from the tail.
      scrollOffset += 1
    }
    log.debug("events.appended kind=\(entry.kind, privacy: .public)")
  }

  public func clear() {
    log.notice("events.cleared prior=\(self.entries.count, privacy: .public)")
    entries.removeAll()
    scrollOffset = 0
  }

  public func scrollUp(_ lines: Int = 1) {
    scrollOffset = min(max(0, scrollOffset + lines), max(0, entries.count - 1))
  }

  public func scrollDown(_ lines: Int = 1) {
    scrollOffset = max(0, scrollOffset - lines)
  }

  // MARK: - Render

  public func render(into buffer: ScreenBuffer, contentRows rows: ClosedRange<Int>) {
    var row = rows.lowerBound
    func write(_ text: String) {
      if row <= rows.upperBound {
        buffer.put(row: row, text)
        row += 1
      }
    }

    let header = "\(Theme.head)EVENTS\(Ansi.reset)  "
      + "\(Theme.dim)\(entries.count) buffered · j/k scrolls · c clears\(Ansi.reset)"
    write(header)
    write("")

    if entries.isEmpty {
      write("\(Theme.dim)(no events yet. broker is offline or idle)\(Ansi.reset)")
      return
    }

    let visible = rows.upperBound - row + 1
    guard visible > 0 else { return }

    // Tail slice: offset 0 == newest, higher offset scrolls back.
    let tailEnd = entries.count - scrollOffset
    let tailStart = max(0, tailEnd - visible)
    for entry in entries[tailStart..<tailEnd] {
      let ts = timestampFormatter.string(from: entry.timestamp)
      let kindColor = color(for: entry.kind)
      var line = "\(Theme.dim)\(ts)\(Ansi.reset)  "
        + "\(kindColor)\(Self.pad(entry.kind, 22))\(Ansi.reset)  "
      if let m = entry.model { line += "\(Theme.label)\(Self.pad(m, 32))\(Ansi.reset)  " }
      line += "\(Theme.text)\(entry.message)\(Ansi.reset)"
      write(line)
    }
  }

  public func handle(_ input: TabInput) -> TabAction {
    switch input {
    case .key(.scrollUp):
      scrollUp()
      log.debug("events.scrolled direction=up offset=\(self.scrollOffset, privacy: .public)")
      return .none
    case .key(.scrollDown):
      scrollDown()
      log.debug("events.scrolled direction=down offset=\(self.scrollOffset, privacy: .public)")
      return .none
    case .key(.top):
      scrollOffset = max(0, entries.count - 1); return .none
    case .key(.bottom):
      scrollOffset = 0; return .none
    case .key(.quit):
      return .quit
    default:
      return .none
    }
  }

  public func handleChar(_ char: Character) -> TabAction {
    if char == "c" { clear(); return .none }
    return .none
  }

  // MARK: - Helpers

  /// Formatter for the timestamp column. Defaults to `HH:mm:ss` in the
  /// host's local timezone. Tests override this to a fixed timezone so
  /// snapshots are deterministic.
  public var timestampFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "HH:mm:ss"
    return f
  }()

  private func color(for kind: String) -> String {
    switch kind {
    case "model.loaded", "request.completed": return Theme.ok
    case "model.unloaded", "model.evicted": return Theme.warn
    case "request.failed": return Theme.bad
    case "pull.started", "pull.progress": return Theme.accent
    case "pull.completed": return Theme.ok
    default: return Theme.text
    }
  }

  private static func pad(_ s: String, _ width: Int) -> String {
    if s.count >= width { return String(s.prefix(width)) }
    return s + String(repeating: " ", count: width - s.count)
  }
}
