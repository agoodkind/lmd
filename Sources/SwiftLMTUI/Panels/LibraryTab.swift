//
//  LibraryTab.swift
//  SwiftLMTUI
//
//  Created by Alex Goodkind <alex@goodkind.io> on 2026-04-18.
//  Copyright (c) 2026
//
//  LibraryTab lists every model on disk. It overlays the broker's
//  currently loaded models state. Rows show a load marker, display name,
//  slug, and size. Selection moves with j or k. Press `l` to preload.
//  Press `u` to unload. Press `/` to enter search mode. Press `s` to
//  cycle sort orders.
//

import AppLogger
import Foundation

private let log = AppLogger.logger(category: "LibraryTab")

// MARK: - DTOs

/// One row in the library. The host builds it from the ModelCatalog plus
/// the `/swiftlmd/loaded` snapshot.
public struct LibraryEntry: Sendable, Equatable {
  public let id: String
  public let displayName: String
  public let slug: String
  public let sizeGB: Double
  public let isLoaded: Bool
  public let inFlightRequests: Int

  public init(
    id: String,
    displayName: String,
    slug: String,
    sizeGB: Double,
    isLoaded: Bool,
    inFlightRequests: Int
  ) {
    self.id = id
    self.displayName = displayName
    self.slug = slug
    self.sizeGB = sizeGB
    self.isLoaded = isLoaded
    self.inFlightRequests = inFlightRequests
  }
}

/// How the library list is ordered.
public enum LibrarySortMode: String, Sendable, CaseIterable {
  case name         // alpha by display name
  case sizeDesc     // largest first
  case loadedFirst  // loaded models above idle ones, alpha within each group
}

// MARK: - LibraryTab

public final class LibraryTab: Tab {
  public let label = "library"
  public let title = "library"

  public var entries: [LibraryEntry] = []
  public private(set) var selection: Int = 0
  public private(set) var pendingCommand: (name: String, payload: [String: String])?

  // Search and sort state.
  public private(set) var query: String = ""
  public private(set) var searchActive: Bool = false
  public private(set) var sortMode: LibrarySortMode = .name

  public init() {}

  /// The entry set after applying the current query filter and sort order.
  /// All navigation and actions operate on this list. They do not operate
  /// on the raw `entries` list directly.
  public var visibleEntries: [LibraryEntry] {
    let filtered: [LibraryEntry]
    if query.isEmpty {
      filtered = entries
    } else {
      let q = query.lowercased()
      filtered = entries.filter {
        $0.displayName.lowercased().contains(q) ||
        $0.slug.lowercased().contains(q) ||
        $0.id.lowercased().contains(q)
      }
    }
    switch sortMode {
    case .name:
      return filtered.sorted { $0.displayName.lowercased() < $1.displayName.lowercased() }
    case .sizeDesc:
      return filtered.sorted { $0.sizeGB > $1.sizeGB }
    case .loadedFirst:
      return filtered.sorted { lhs, rhs in
        if lhs.isLoaded != rhs.isLoaded { return lhs.isLoaded }
        return lhs.displayName.lowercased() < rhs.displayName.lowercased()
      }
    }
  }

  /// The entry currently highlighted for `l` or `u` or `d` actions. It is
  /// also used to seed the chat tab with a model. Returns nil when the
  /// visible list is empty.
  public func selectedEntry() -> LibraryEntry? {
    let list = visibleEntries
    guard selection >= 0, selection < list.count else { return nil }
    return list[selection]
  }

  // MARK: Search mode, driven by the host input loop

  public func beginSearch() {
    searchActive = true
    query = ""
    selection = 0
    log.debug("library.search_begin")
  }

  public func appendSearchChar(_ ch: Character) {
    guard searchActive else { return }
    query.append(ch)
    selection = 0
  }

  public func backspaceSearch() {
    guard searchActive else { return }
    if !query.isEmpty { query.removeLast() }
    selection = 0
  }

  public func cancelSearch() {
    searchActive = false
    query = ""
    selection = 0
    log.debug("library.search_cancel")
  }

  public func commitSearch() {
    searchActive = false
    selection = 0
    log.debug("library.search_commit query=\(self.query, privacy: .public)")
  }

  public func cycleSort() {
    let all = LibrarySortMode.allCases
    if let idx = all.firstIndex(of: sortMode) {
      sortMode = all[(idx + 1) % all.count]
    }
    selection = 0
    log.debug("library.sort_mode=\(self.sortMode.rawValue, privacy: .public)")
  }

  // MARK: Render

  public func render(into buffer: ScreenBuffer, contentRows rows: ClosedRange<Int>) {
    let totalCols = max(40, buffer.cols)
    // Details pane on the right. Collapses on narrow terminals.
    let detailsWidth = totalCols >= 90 ? 36 : 0
    let sepWidth = detailsWidth > 0 ? 3 : 0
    let listWidth = totalCols - detailsWidth - sepWidth

    let visible = visibleEntries
    let sortLabel: String
    switch sortMode {
    case .name:         sortLabel = "name"
    case .sizeDesc:     sortLabel = "size"
    case .loadedFirst:  sortLabel = "loaded"
    }

    var listLines: [String] = []
    let header: String
    if query.isEmpty {
      header = "\(Theme.head)MODELS\(Ansi.reset)  \(Theme.dim)\(entries.count) · sort:\(sortLabel) · / search · s sort\(Ansi.reset)"
    } else {
      header = "\(Theme.head)MODELS\(Ansi.reset)  \(Theme.dim)\(visible.count)/\(entries.count) · \"\(query)\" · esc clear\(Ansi.reset)"
    }
    listLines.append(header)

    if searchActive {
      listLines.append("\(Theme.accent)SEARCH\(Ansi.reset) \(Theme.text)\(query)\(Ansi.reset)\(Theme.accent)▏\(Ansi.reset)")
    } else {
      listLines.append("")
    }

    if entries.isEmpty {
      listLines.append("\(Theme.dim)no models found under ~/.lmstudio/models or HF cache\(Ansi.reset)")
    } else if visible.isEmpty {
      listLines.append("\(Theme.dim)no matches for \"\(query)\"\(Ansi.reset)")
    } else {
      // prefix(4) + marker(8) + gap(2) + name + gap(2) + size(9) = listWidth
      let nameWidth = max(8, listWidth - 4 - 8 - 2 - 2 - 9)
      let available = max(1, rows.upperBound - rows.lowerBound + 1 - listLines.count)
      let visibleCount = min(available, visible.count)
      var windowStart = max(0, selection - visibleCount / 2)
      if windowStart + visibleCount > visible.count {
        windowStart = max(0, visible.count - visibleCount)
      }
      for i in windowStart..<min(visible.count, windowStart + visibleCount) {
        let entry = visible[i]
        let selected = i == selection
        let marker: String
        if entry.isLoaded && entry.inFlightRequests > 0 {
          marker = "\(Theme.bad)● busy  \(Ansi.reset)"
        } else if entry.isLoaded {
          marker = "\(Theme.ok)● loaded\(Ansi.reset)"
        } else {
          marker = "\(Theme.dim)○ idle  \(Ansi.reset)"
        }
        let sizeStr = entry.sizeGB >= 0.1 ? String(format: "%6.1f GB", entry.sizeGB) : "     n/a"
        let nameCol = VisibleText.pad(VisibleText.truncate(entry.displayName, nameWidth), nameWidth)
        let prefix = selected
          ? "\(Theme.barBg)\(Theme.barFg) > \(Ansi.reset)"
          : "    "
        listLines.append("\(prefix)\(marker)  \(Theme.text)\(nameCol)\(Ansi.reset)  \(Theme.text)\(sizeStr)\(Ansi.reset)")
      }
    }

    // Build details pane lines.
    var detailLines: [String] = []
    if detailsWidth > 0 {
      detailLines.append("\(Theme.head)DETAILS\(Ansi.reset)")
      detailLines.append("")
      if let e = selectedEntry() {
        let status: String
        if e.isLoaded && e.inFlightRequests > 0 {
          status = "\(Theme.bad)busy\(Ansi.reset) (\(e.inFlightRequests) in-flight)"
        } else if e.isLoaded {
          status = "\(Theme.ok)loaded\(Ansi.reset)"
        } else {
          status = "\(Theme.dim)idle\(Ansi.reset)"
        }
        let sizeText = e.sizeGB >= 0.1 ? String(format: "%.1f GB", e.sizeGB) : "n/a"
        func kv(_ k: String, _ v: String) -> String {
          "\(Theme.dim)\(VisibleText.pad(k, 7))\(Ansi.reset) \(v)"
        }
        detailLines.append(kv("status", status))
        detailLines.append(kv("size", sizeText))
        detailLines.append("")
        detailLines.append("\(Theme.dim)name\(Ansi.reset)")
        detailLines.append(VisibleText.truncate(e.displayName, detailsWidth))
        detailLines.append("")
        detailLines.append("\(Theme.dim)slug\(Ansi.reset)")
        // Wrap slug across up to 3 lines so the full path is visible.
        let slug = e.slug
        var remaining = slug
        for _ in 0..<3 {
          if remaining.isEmpty { break }
          let chunk = String(remaining.prefix(detailsWidth))
          detailLines.append(chunk)
          remaining = String(remaining.dropFirst(chunk.count))
        }
        detailLines.append("")
        detailLines.append("\(Theme.dim)l\(Ansi.reset) load    \(Theme.dim)u\(Ansi.reset) unload")
      } else {
        detailLines.append("\(Theme.dim)(no selection)\(Ansi.reset)")
      }
    }

    // Write combined left + separator + right per row.
    let separator = detailsWidth > 0 ? " \(Theme.dim)│\(Ansi.reset) " : ""
    var row = rows.lowerBound
    let maxRows = rows.upperBound - rows.lowerBound + 1
    for i in 0..<maxRows {
      let left = i < listLines.count ? listLines[i] : ""
      let right = (detailsWidth > 0 && i < detailLines.count) ? detailLines[i] : ""
      let leftPadded = VisibleText.pad(VisibleText.truncate(left, listWidth), listWidth)
      buffer.put(row: row, leftPadded + separator + right)
      row += 1
    }
  }

  // MARK: Input

  public func handle(_ input: TabInput) -> TabAction {
    log.debug("library.input_handled selection=\(self.selection, privacy: .public)")
    pendingCommand = nil
    let count = visibleEntries.count
    switch input {
    case .key(.scrollDown):
      if count > 0 { selection = min(selection + 1, count - 1) }
      return .none
    case .key(.scrollUp):
      if count > 0 { selection = max(selection - 1, 0) }
      return .none
    case .key(.top):
      selection = 0; return .none
    case .key(.bottom):
      if count > 0 { selection = count - 1 }
      return .none
    case .key(.quit):
      // While composing a search query, `q` is a literal character. It is
      // not a quit. The host does not know about search mode so we guard
      // here.
      if searchActive { return .none }
      return .quit
    case .key(.unknown):
      return .none
    case .key(.pageDown):
      selection = min(selection + 10, max(0, count - 1))
      return .none
    case .key(.pageUp):
      selection = max(selection - 10, 0)
      return .none
    case .mouseWheel, .mouseClick, .resized, .tick:
      return .none
    }
  }

  /// Host calls this for single char keys. Returns a TabAction the router
  /// acts on. In search mode most printable chars append to the query.
  public func handleChar(_ char: Character) -> TabAction {
    if searchActive {
      if char.asciiValue.map({ $0 >= 0x20 && $0 < 0x7F }) == true {
        appendSearchChar(char)
      }
      return .none
    }
    switch char {
    case "/":
      beginSearch()
      return .none
    case "s":
      cycleSort()
      return .none
    default:
      break
    }
    guard let entry = selectedEntry() else { return .none }
    switch char {
    case "l":
      log.notice("library.preload_requested model=\(entry.id, privacy: .public)")
      return .command(name: "preload", payload: ["model": entry.id])
    case "u":
      log.notice("library.unload_requested model=\(entry.id, privacy: .public)")
      return .command(name: "unload", payload: ["model": entry.id])
    case "d":
      log.notice("library.delete_requested model=\(entry.id, privacy: .public)")
      return .command(name: "delete", payload: ["model": entry.id])
    case "p":
      log.notice("library.pull_requested")
      return .command(name: "pull_hint", payload: [:])
    default:
      log.debug("library.key_unhandled key=\(String(char), privacy: .public)")
      return .none
    }
  }
}
