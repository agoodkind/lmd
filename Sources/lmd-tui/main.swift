//
//  main.swift
//  swiftlmui
//
//  Created by Alex Goodkind <alex@goodkind.io> on 2026-04-18.
//  Copyright © 2026
//
//  Phase 3 unified TUI. Hosts a TabRouter with monitor and library tabs.
//  Reads sensor state from memory.jsonl (populated by swiftmon) and
//  broker state from XPC and ModelRouter snapshots.
//

import AppLogger
import Darwin
import Foundation
import SwiftLMCore
import SwiftLMControl
import SwiftLMRuntime
import SwiftLMTUI

AppLogger.bootstrap(subsystem: "io.goodkind.lmd")
private let log = AppLogger.logger(category: "TUIHost")

log.info("tui.starting pid=\(getpid(), privacy: .public)")

// MARK: - Configuration

private func sayErr(_ s: String) {
  FileHandle.standardError.write((s + "\n").data(using: .utf8) ?? Data())
}

let broker: BrokerClient = {
  do {
    return try BrokerClient()
  } catch {
    log.error("tui.broker_unavailable err=\(String(describing: error), privacy: .public)")
    sayErr("lmd-tui: broker unavailable, install deploy/io.goodkind.lmd.serve.plist.example")
    sayErr("    underlying error: \(error)")
    exit(7)
  }
}()

let memoryPath = "/Users/agoodkind/Sites/lm-review-stress-test/configs-battery/memory.jsonl"

// MARK: - Snapshot readers

/// Parse the latest memory.jsonl row into a MonitorSnapshot.
func latestMonitorSnapshot() -> MonitorSnapshot {
  guard let fh = FileHandle(forReadingAtPath: memoryPath) else { return .empty }
  defer { try? fh.close() }
  let size = (try? fh.seekToEnd()) ?? 0
  let tail: UInt64 = min(size, 8192)
  try? fh.seek(toOffset: size - tail)
  let data = fh.readDataToEndOfFile()
  guard let text = String(data: data, encoding: .utf8) else { return .empty }
  let lines = text.split(separator: "\n").map(String.init)
  for line in lines.reversed() where !line.isEmpty {
    guard let jsonData = line.data(using: .utf8),
          let obj = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any]
    else { continue }
    return MonitorSnapshot.from(json: obj)
  }
  return .empty
}

/// Build LibraryTab entries by unioning the on-disk catalog with the
/// broker's `/loaded` snapshot.
func latestLibraryEntries() -> [LibraryEntry] {
  let catalog = ModelCatalog(roots: ModelCatalog.defaultRoots)
  let disk = catalog.allModels().filter { $0.sizeBytes > 0 }
  let loadedByID: [String: (Double, Int)] = {
    let result = runBlocking { try await broker.loaded() }
    switch result {
    case .success(let snap):
      var next: [String: (Double, Int)] = [:]
      for model in snap.models {
        next[model.modelID] = (model.sizeGB, model.inFlightRequests)
      }
      return next
    case .failure(let err):
      log.error("library.loaded_failed err=\(String(describing: err), privacy: .public)")
      return [:]
    }
  }()

  return disk.map { desc in
    let loaded = loadedByID[desc.id]
    return LibraryEntry(
      id: desc.id,
      displayName: desc.displayName,
      slug: desc.slug ?? "-",
      sizeGB: Double(desc.sizeBytes) / 1_073_741_824,
      isLoaded: loaded != nil,
      inFlightRequests: loaded?.1 ?? 0
    )
  }
}

// MARK: - Boot

Screen.installRestoreOnExit()
Screen.enter(enableMouse: true)

// Use explicit KeyParser + MouseParser inputs; tests never see raw stdin.
let monitor = MonitorTab()
let library = LibraryTab()
let bench = BenchTab()
let events = EventsTab()
let router = TabRouter(tabs: [monitor, library, bench, events])

// Signals
signal(SIGINT, SIG_IGN)
signal(SIGTERM, SIG_IGN)
signal(SIGPIPE, SIG_IGN)
let sigInt = DispatchSource.makeSignalSource(signal: SIGINT)
let sigTerm = DispatchSource.makeSignalSource(signal: SIGTERM)
sigInt.setEventHandler { exit(0) }
sigTerm.setEventHandler { exit(0) }
sigInt.resume()
sigTerm.resume()

// Global state shared between render and input threads.
let stateLock = NSLock()

func appendEvent(_ event: BrokerEvent) {
  let message = event.message.isEmpty ? event.kind.rawValue : event.message
  stateLock.lock()
  events.append(EventEntry(
    kind: event.kind.rawValue,
    model: event.model ?? "-",
    message: message,
    timestamp: event.ts
  ))
  stateLock.unlock()
  renderFrame()
}

// Raw terminal mode: disable echo and canonical line buffering so individual
// keystrokes are delivered immediately and not echoed back to the screen.
var origTermios = termios()
tcgetattr(0, &origTermios)
var rawTermios = origTermios
rawTermios.c_lflag &= ~(UInt(ICANON) | UInt(ECHO))
tcsetattr(0, TCSANOW, &rawTermios)

func restoreTerminalMode() {
  tcsetattr(0, TCSANOW, &origTermios)
}
atexit(restoreTerminalMode)

// Non-blocking stdin for the input loop.
let tcFlags = fcntl(0, F_GETFL, 0)
_ = fcntl(0, F_SETFL, tcFlags | O_NONBLOCK)

// MARK: - Render

final class TerminalBuffer: ScreenBuffer {
  var rows: Int
  var cols: Int
  private(set) var rowsPainted: [Int: String] = [:]
  init(rows: Int, cols: Int) {
    self.rows = rows
    self.cols = cols
  }
  func put(row: Int, _ text: String) { rowsPainted[row] = text }
  func reset() { rowsPainted.removeAll(keepingCapacity: true) }
}

var previousFrame: [Int: String] = [:]

func renderFrame() {
  let (rows, cols) = Screen.currentSize()
  let buffer = TerminalBuffer(rows: rows, cols: cols)

  // Top bar: full-width background with tab labels.
  let barBg = Theme.barBg
  let barFg = Theme.barFg
  let barAccent = Theme.barAccent
  let title = " \(barAccent)▌ lmd \(barFg)  "
  let tabBar = router.tabBar(active: barAccent, dim: Theme.barDim, reset: Ansi.reset + barBg + barFg)
  let topFill = max(0, cols - VisibleText.width(title) - VisibleText.width(tabBar) - 1)
  let topBar = barBg + title + tabBar + String(repeating: " ", count: topFill) + Ansi.reset
  buffer.put(row: 1, topBar)

  // Content area rows 3..<rows
  router.render(into: buffer, contentRows: 3...(rows - 1))

  // Bottom bar. The "1-N" hint mirrors the actual tab count so the
  // user never sees digits that do nothing. Also drop typographic
  // dashes in favor of ASCII slashes and dots for copy-paste safety
  // and to stay out of the `remove-emdashes` audit lane.
  let footBg = Theme.footBg
  let footFg = Theme.footFg
  let tabCount = router.tabs.count
  let keys = " \(footBg)\(footFg)tab/1-\(tabCount) switch . j/k move . l load . u unload . q quit \(Ansi.reset)"
  let bottomFill = max(0, cols - VisibleText.width(keys))
  let bottomBar = keys + footBg + String(repeating: " ", count: bottomFill) + Ansi.reset
  buffer.put(row: rows, bottomBar)

  // Flush: only write rows that changed.
  var written: Set<Int> = []
  var out = ""
  for (row, text) in buffer.rowsPainted {
    written.insert(row)
    if previousFrame[row] == text {
      continue
    }
    previousFrame[row] = text
    out += Ansi.move(row, 1) + Ansi.clearLine + text
  }
  // Clear rows that were painted last frame but not this one.
  for (row, _) in previousFrame where !written.contains(row) {
    out += Ansi.move(row, 1) + Ansi.clearLine
    previousFrame.removeValue(forKey: row)
  }

  if !out.isEmpty {
    Screen.write(out)
  }
}

// Initial paint and snapshot seed.
monitor.snapshot = latestMonitorSnapshot()
library.entries = latestLibraryEntries()
Screen.clearViewport()
renderFrame()

let eventsStream = broker.events()
Task.detached {
  do {
    for try await event in eventsStream {
      appendEvent(event)
    }
  } catch {
    log.error("tui.events_stream_failed err=\(String(describing: error), privacy: .public)")
  }
}

// MARK: - Background refresher

let refreshQueue = DispatchQueue(label: "swiftlmui.refresh", qos: .utility)
refreshQueue.async {
  while true {
    Thread.sleep(forTimeInterval: 2.0)
    let snap = latestMonitorSnapshot()
    let entries = latestLibraryEntries()
    stateLock.lock()
    monitor.snapshot = snap
    library.entries = entries
    stateLock.unlock()
    renderFrame()
  }
}

// MARK: - Input loop

let inputQueue = DispatchQueue(label: "swiftlmui.input", qos: .userInteractive)
inputQueue.async {
  var buf = [UInt8](repeating: 0, count: 32)
  while true {
    let n = read(0, &buf, 32)
    if n <= 0 {
      Thread.sleep(forTimeInterval: 0.05)
      continue
    }

    // Tab key switches to next tab. Clear the viewport and the differential
    // render state so the new tab paints from a blank slate. Hold the lock
    // across the clearViewport write so the refresh thread cannot repaint
    // stale previousFrame entries between our clear and our renderFrame.
    if n == 1 && buf[0] == 0x09 {
      stateLock.lock()
      let next = (router.activeIndex + 1) % router.tabs.count
      router.setActive(index: next)
      previousFrame.removeAll()
      Screen.clearViewport()
      stateLock.unlock()
      renderFrame()
      continue
    }

    // Library search mode takes precedence over tab number switching so
    // that digits typed into the search query are not intercepted.
    if n == 1, let lib = router.activeTab as? LibraryTab, lib.searchActive {
      let b = buf[0]
      if b == 0x1B {
        // Escape cancels search.
        stateLock.lock(); lib.cancelSearch(); stateLock.unlock()
        renderFrame(); continue
      }
      if b == 0x0D || b == 0x0A {
        // Enter commits search.
        stateLock.lock(); lib.commitSearch(); stateLock.unlock()
        renderFrame(); continue
      }
      if b == 0x7F || b == 0x08 {
        stateLock.lock(); lib.backspaceSearch(); stateLock.unlock()
        renderFrame(); continue
      }
      if b >= 0x20 && b < 0x7F {
        let ch = Character(UnicodeScalar(b))
        stateLock.lock(); lib.appendSearchChar(ch); stateLock.unlock()
        renderFrame(); continue
      }
      // Fall through for anything else so the normal handlers apply.
    }

    // Number keys 1-9 select tab directly. Same clear-on-switch as Tab.
    if n == 1, buf[0] >= UInt8(ascii: "1"), buf[0] <= UInt8(ascii: "9") {
      let digit = Int(buf[0] - UInt8(ascii: "0"))
      stateLock.lock()
      router.setActive(index: min(digit - 1, router.tabs.count - 1))
      previousFrame.removeAll()
      Screen.clearViewport()
      stateLock.unlock()
      renderFrame()
      continue
    }

    // Library single char keys: l/u/d/p actions plus / for search and s for
    // sort toggle. Dispatched through LibraryTab.handleChar.
    if n == 1, let active = router.activeTab as? LibraryTab {
      let char = Character(UnicodeScalar(buf[0]))
      if "luds/".contains(char) || char == "p" {
        stateLock.lock()
        let action = active.handleChar(char)
        stateLock.unlock()
        handleAction(action)
        renderFrame()
        continue
      }
    }

    // Try SGR mouse event first (ESC [ < ... M/m sequences).
    if n >= 6 && buf[0] == 0x1B {
      if let mouseEvent = MouseParser.parse(Array(buf[0..<n]), start: 0, length: n) {
        let input: TabInput = (mouseEvent.isWheelUp || mouseEvent.isWheelDown)
          ? .mouseWheel(mouseEvent)
          : .mouseClick(mouseEvent)
        stateLock.lock()
        let action = router.handle(input)
        stateLock.unlock()
        handleAction(action)
        renderFrame()
        continue
      }
    }

    // Otherwise, decode via KeyParser.
    let event = KeyParser.parse(Array(buf[0..<n]), start: 0, length: n)
    stateLock.lock()
    let action = router.handle(.key(event))
    stateLock.unlock()
    handleAction(action)
    renderFrame()
  }
}

func handleAction(_ action: TabAction) {
  switch action {
  case .quit:
    exit(0)
  case .command(let name, let payload):
    switch name {
    case "preload":
      if let m = payload["model"] {
        Task.detached {
          do {
            try await broker.preload(model: m)
          } catch {
            log.error("tui.preload_failed model=\(m, privacy: .public) err=\(String(describing: error), privacy: .public)")
          }
        }
      }
    case "unload":
      if let m = payload["model"] {
        Task.detached {
          do {
            try await broker.unload(model: m)
          } catch {
            log.error("tui.unload_failed model=\(m, privacy: .public) err=\(String(describing: error), privacy: .public)")
          }
        }
      }
    default:
      break
    }
  case .switchTo, .none:
    break
  }
}

RunLoop.main.run()
