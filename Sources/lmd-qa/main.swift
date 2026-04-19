// tuiqa: interactive TUI QA driver.
//
// Three-layer driver stack:
//   L1 tmux: nested pty. Fast. Keystrokes via tmux send-keys.
//   L2 pty:  raw macOS pty via SwiftTerm HeadlessTerminal. Canonical terminal semantics.
//   L3 iterm: real iTerm window via osascript. The actual user environment.
//
// All three drivers run the same QA assertion sequences and honor the same
// coverage manifest at Tests/Fixtures/tuiqa-coverage.txt. Mouse events are injected as
// raw SGR bytes under every driver. Default run exercises L1 + L2 + L3.
//
// Usage:
//   tuiqa                       L1 + L2 + L3 (default)
//   tuiqa --driver tmux         L1 only (fast dev iteration)
//   tuiqa --driver pty          L2 only
//   tuiqa --driver iterm        L3 only
//   tuiqa --driver tmux,pty     explicit opt-out from L3
//   tuiqa lmd-tui             scope to one binary across all drivers
//   tuiqa --no-coverage         skip coverage check
//
// Environment:
//   LMD_BINARY_DIR       path to release binaries (default: .build/release)
//   TUIQA_COVERAGE_FILE         path to coverage manifest (default: Tests/Fixtures/tuiqa-coverage.txt)

import Foundation
import SwiftTerm

// MARK: Shell helper

@discardableResult
func sh(_ args: [String], input: Data? = nil) -> String {
  let proc = Process()
  proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
  proc.arguments = args
  let out = Pipe()
  proc.standardOutput = out
  proc.standardError = Pipe()
  if let data = input {
    let inPipe = Pipe()
    proc.standardInput = inPipe
    inPipe.fileHandleForWriting.write(data)
    inPipe.fileHandleForWriting.closeFile()
  }
  try? proc.run()
  proc.waitUntilExit()
  return String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
}

func settle(_ seconds: Double) {
  Thread.sleep(forTimeInterval: seconds)
}

// MARK: CLI output
//
// `lmd-qa` is a CLI reporting tool. Its output is user-visible (PASS/FAIL
// lines, coverage reports, rendered screens). Per Rule 5 of the Apple-native
// logging policy, user-facing CLI output stays on stdout via
// `FileHandle.standardOutput.write`. Use `say` for anything meant for the
// operator's terminal; reserve `log.<level>` for diagnostics (which we do
// not emit here yet).

private func say(_ s: String = "") {
  FileHandle.standardOutput.write((s + "\n").data(using: .utf8) ?? Data())
}

// MARK: Key encoding

// Key names match tmux send-keys conventions so the QA sequence reads the
// same under every driver. Each driver translates these symbolic names into
// the raw bytes or iTerm syntax it needs.
enum TuiqaKey {
  // Translate a key name to raw bytes that the TUI will read from stdin.
  // Used by PTY and iTerm drivers.
  static func bytes(for key: String) -> [UInt8] {
    switch key {
    case "Enter":  return [0x0D]
    case "Tab":    return [0x09]
    case "BSpace": return [0x7F]
    case "Escape": return [0x1B]
    case "Space":  return [0x20]
    case "Up":     return [0x1B, 0x5B, 0x41]
    case "Down":   return [0x1B, 0x5B, 0x42]
    case "Right":  return [0x1B, 0x5B, 0x43]
    case "Left":   return [0x1B, 0x5B, 0x44]
    case "PageUp":   return [0x1B, 0x5B, 0x35, 0x7E]
    case "PageDown": return [0x1B, 0x5B, 0x36, 0x7E]
    default:
      return Array(key.utf8)
    }
  }
}

// MARK: TUIDriver protocol

protocol TUIDriver: AnyObject {
  var name: String { get }
  func start(_ binary: String)
  func kill()
  func sendKey(_ key: String)
  func capture() -> String
  func sessionExists() -> Bool
  // Inject raw bytes directly into the child's stdin. Used for SGR mouse events.
  func pasteRaw(_ bytes: [UInt8])
}

// Shared mouse helpers build SGR 1006 sequences then hand them to pasteRaw.
// Button codes: 0 = left click, 64 = wheel up, 65 = wheel down,
// 66 = wheel left, 67 = wheel right, 35 = motion no-button (hover).
extension TUIDriver {
  func mouseClick(col: Int = 60, row: Int = 20) {
    var press = Array("\u{001B}[<0;\(col);\(row)M".utf8)
    pasteRaw(press)
    settle(0.05)
    press = Array("\u{001B}[<0;\(col);\(row)m".utf8)
    pasteRaw(press)
  }

  func mouseScrollDown(col: Int = 60, row: Int = 20, times: Int = 3) {
    for _ in 0..<times {
      pasteRaw(Array("\u{001B}[<65;\(col);\(row)M".utf8))
      settle(0.05)
    }
  }

  func mouseScrollUp(col: Int = 60, row: Int = 20, times: Int = 3) {
    for _ in 0..<times {
      pasteRaw(Array("\u{001B}[<64;\(col);\(row)M".utf8))
      settle(0.05)
    }
  }

  // Hover in place at (col, row) then scroll. Used to verify region-scoped
  // scroll behavior: the region under the cursor should scroll, other
  // regions should not.
  func mouseHoverAndScroll(col: Int, row: Int, scrollDown: Bool = true, times: Int = 3) {
    // Motion-without-button (button 35).
    pasteRaw(Array("\u{001B}[<35;\(col);\(row)M".utf8))
    settle(0.05)
    let btn = scrollDown ? 65 : 64
    for _ in 0..<times {
      pasteRaw(Array("\u{001B}[<\(btn);\(col);\(row)M".utf8))
      settle(0.05)
    }
  }
}

// MARK: TmuxDriver (L1)

final class TmuxDriver: TUIDriver {
  let name = "tmux"
  let sessionName: String
  let cols: Int
  let rows: Int

  init(cols: Int = 120, rows: Int = 40) {
    self.sessionName = "tuiqa-tmux-\(ProcessInfo.processInfo.processIdentifier)"
    self.cols = cols
    self.rows = rows
  }

  func start(_ binary: String) {
    kill()
    sh(["tmux", "new-session", "-d", "-s", sessionName, "-x", "\(cols)", "-y", "\(rows)", binary])
  }

  func kill() {
    sh(["tmux", "kill-session", "-t", sessionName])
  }

  func sendKey(_ key: String) {
    sh(["tmux", "send-keys", "-t", sessionName, key, ""])
  }

  func capture() -> String {
    sh(["tmux", "capture-pane", "-t", sessionName, "-p"])
  }

  func sessionExists() -> Bool {
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    proc.arguments = ["tmux", "has-session", "-t", sessionName]
    proc.standardOutput = Pipe()
    proc.standardError = Pipe()
    try? proc.run()
    proc.waitUntilExit()
    return proc.terminationStatus == 0
  }

  func pasteRaw(_ bytes: [UInt8]) {
    let data = Data(bytes)
    sh(["tmux", "load-buffer", "-"], input: data)
    sh(["tmux", "paste-buffer", "-t", sessionName])
  }
}

// MARK: PTYDriver (L2)

// Wraps SwiftTerm.HeadlessTerminal which forks a real macOS pty via
// forkpty() under the hood, runs the binary as a child, and parses its
// output bytes into a grid through SwiftTerm's Terminal emulator. This
// is the canonical "what would happen in a real terminal" driver.
final class PTYDriver: TUIDriver {
  let name = "pty"
  let cols: Int
  let rows: Int
  private var term: HeadlessTerminal?
  private var exitCode: Int32?
  private var exitedAtomic = NSLock()

  init(cols: Int = 120, rows: Int = 40) {
    self.cols = cols
    self.rows = rows
  }

  func start(_ binary: String) {
    let queue = DispatchQueue(label: "tuiqa.pty.\(ProcessInfo.processInfo.processIdentifier)")
    let opts = TerminalOptions(cols: cols, rows: rows)
    let ht = HeadlessTerminal(queue: queue, options: opts) { [weak self] code in
      guard let self = self else { return }
      self.exitedAtomic.lock()
      self.exitCode = code ?? -1
      self.exitedAtomic.unlock()
    }
    term = ht
    // Propagate standard env vars the child expects (HOME, PATH, etc.) plus
    // force TERM to a modern profile SwiftTerm renders correctly.
    var env = ProcessInfo.processInfo.environment
    env["TERM"] = "xterm-256color"
    env["COLUMNS"] = "\(cols)"
    env["LINES"] = "\(rows)"
    let envArr = env.map { "\($0.key)=\($0.value)" }
    ht.process.startProcess(
      executable: binary, args: [], environment: envArr, execName: nil
    )
  }

  func kill() {
    term?.process.terminate()
  }

  func sendKey(_ key: String) {
    let bytes = TuiqaKey.bytes(for: key)
    pasteRaw(bytes)
  }

  func pasteRaw(_ bytes: [UInt8]) {
    guard let ht = term else { return }
    ht.send(data: ArraySlice(bytes))
  }

  func capture() -> String {
    guard let ht = term else { return "" }
    let data = ht.terminal.getBufferAsData()
    return String(data: data, encoding: .utf8) ?? ""
  }

  func sessionExists() -> Bool {
    exitedAtomic.lock()
    defer { exitedAtomic.unlock() }
    return exitCode == nil
  }
}

// MARK: ITermDriver (L3)

// Drives an actual iTerm window via AppleScript. Requires iTerm2 to be
// installed and Automation permission granted for the host terminal.
final class ITermDriver: TUIDriver {
  let name = "iterm"
  private let sessionTag: String
  // iTerm's own immutable session id, captured on start. We use this for
  // all later ops because the session's `name` can be overwritten by the
  // child process (e.g. lmd-tui sets the terminal title). The id is set
  // at window creation and never changes.
  private var sessionID: String = ""
  private var started = false

  init() {
    self.sessionTag = "tuiqa-\(ProcessInfo.processInfo.processIdentifier)"
  }

  private func osa(_ script: String) -> String {
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    proc.arguments = ["-e", script]
    let out = Pipe()
    let err = Pipe()
    proc.standardOutput = out
    proc.standardError = err
    try? proc.run()
    proc.waitUntilExit()
    let o = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    return o.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  // Escape bytes for embedding in an AppleScript string literal.
  // iTerm's "write text" interprets \e, \n, \t, \r, \b, \a inside its
  // string argument. We emit those for known control bytes. Everything
  // else is escaped via \xNN using AppleScript's ascii character 1-255.
  private func escapeForWriteText(_ bytes: [UInt8]) -> String {
    var parts: [String] = []
    var literal = ""
    func flushLiteral() {
      if !literal.isEmpty {
        let esc = literal
          .replacingOccurrences(of: "\\", with: "\\\\")
          .replacingOccurrences(of: "\"", with: "\\\"")
        parts.append("\"\(esc)\"")
        literal = ""
      }
    }
    for b in bytes {
      if b == 0x1B { flushLiteral(); parts.append("(ASCII character 27)") }
      else if b == 0x0D { flushLiteral(); parts.append("(ASCII character 13)") }
      else if b == 0x0A { flushLiteral(); parts.append("(ASCII character 10)") }
      else if b == 0x09 { flushLiteral(); parts.append("(ASCII character 9)") }
      else if b == 0x7F { flushLiteral(); parts.append("(ASCII character 127)") }
      else if b == 0x08 { flushLiteral(); parts.append("(ASCII character 8)") }
      else if b >= 0x20 && b < 0x7F {
        literal.append(Character(UnicodeScalar(b)))
      } else {
        flushLiteral()
        parts.append("(ASCII character \(b))")
      }
    }
    flushLiteral()
    if parts.isEmpty { return "\"\"" }
    return parts.joined(separator: " & ")
  }

  func start(_ binary: String) {
    // Close any leftover tuiqa windows from interrupted earlier runs before
    // we open a fresh one. Matches any session whose name begins with
    // "tuiqa-" not just our own tag so we handle crashes cleanly.
    cleanupAllTuiqaWindows()

    // Resolve to an absolute path so it does not depend on the iTerm
    // window's default working directory.
    let abs = NSString(string: binary).expandingTildeInPath
    let absolute = (abs as NSString).isAbsolutePath
      ? abs
      : (FileManager.default.currentDirectoryPath as NSString).appendingPathComponent(abs)
    let safePath = absolute.replacingOccurrences(of: "\\", with: "\\\\")
                           .replacingOccurrences(of: "\"", with: "\\\"")
    // Create window and run the binary as the session command directly.
    // Bypassing the shell avoids interference from shell plugins like
    // zsh-autosuggestions that fight with `write text` and insert phantom
    // characters. The session dies cleanly when the binary exits, so
    // sessionExists() gets a reliable signal for the quit assertion.
    sessionID = osa("""
      tell application "iTerm"
        activate
        set newWindow to (create window with default profile command "\(safePath)")
        set theSession to current session of newWindow
        tell theSession
          set name to "\(sessionTag)"
        end tell
        return id of theSession
      end tell
    """)
    started = true
    // Give iTerm a moment to spawn and for the binary to take over the pty.
    settle(0.8)
  }

  // Close every iTerm window that still has a session name starting with
  // "tuiqa-". Idempotent. Used both on start (cleanup from prior runs) and
  // kill (cleanup of the current run).
  //
  // Matches on two signals so we never leave a dead "Session Ended"
  // window around.
  //
  // The first signal is a session name that still starts with our tag
  // "tuiqa-<pid>". That is the common case when launching a plain
  // binary that does not set its own title.
  //
  // The second signal is a session whose child process already exited.
  // A TUI such as lmd-tui overrides the session name via the xterm
  // title escape, so the tag match misses the dead window after quit.
  // Closing iTerm windows whose current session has is_processing set
  // to false is safe here. Real user shells keep a zsh or bash running
  // inside the session, so a real interactive session is always
  // processing and will not be swept.
  private func cleanupAllTuiqaWindows() {
    _ = osa("""
      tell application "iTerm"
        try
          set toClose to {}
          repeat with w in windows
            try
              set sess to current session of w
              set shouldClose to false
              try
                if name of sess starts with "tuiqa-" then set shouldClose to true
              end try
              try
                if is processing of sess is false then set shouldClose to true
              end try
              if shouldClose then copy w to end of toClose
            end try
          end repeat
          repeat with w in toClose
            try
              close w
            end try
          end repeat
        end try
      end tell
    """)
  }

  func kill() {
    guard started else { return }
    // Close the specific window we opened, matched by the captured
    // session id. This avoids racing with other iTerm work the user
    // has open. The broad sweep below is a safety net for crashed
    // sessions from previous runs.
    if !sessionID.isEmpty {
      _ = osa("""
        tell application "iTerm"
          try
            repeat with w in windows
              repeat with t in tabs of w
                repeat with s in sessions of t
                  try
                    if (id of s as string) is "\(sessionID)" then
                      close w
                      exit repeat
                    end if
                  end try
                end repeat
              end repeat
            end try
          end tell
      """)
    }
    cleanupAllTuiqaWindows()
    started = false
  }

  func sendKey(_ key: String) {
    let bytes = TuiqaKey.bytes(for: key)
    pasteRaw(bytes)
  }

  func pasteRaw(_ bytes: [UInt8]) {
    guard !sessionID.isEmpty else { return }
    let payload = escapeForWriteText(bytes)
    _ = osa(scriptTargetingSession(body: """
      tell s
        write text \(payload) newline NO
      end tell
    """))
  }

  // Iterate every session across every tab across every window and pick the
  // one whose id matches. Simpler and more reliable than the nested whose
  // filter which has quirks in older AppleScript versions.
  private func scriptTargetingSession(body: String) -> String {
    return """
      tell application "iTerm"
        try
          repeat with w in windows
            repeat with t in tabs of w
              repeat with s in sessions of t
                try
                  if (id of s as string) is "\(sessionID)" then
                    \(body)
                  end if
                end try
              end repeat
            end repeat
          end repeat
        end try
        return ""
      end tell
    """
  }

  func capture() -> String {
    guard !sessionID.isEmpty else { return "" }
    // `contents` returns only the currently visible screen (no scrollback).
    // Using `text` pulls in scrollback which conflates historical frames
    // from previous tab renders with the live view and makes it impossible
    // to tell what the TUI is actually showing right now.
    return osa(scriptTargetingSession(body: "return contents of s"))
  }

  // The shell was started with `binary; exit` so when the TUI quits, the
  // shell quits too and iTerm closes the session. "Session exists" therefore
  // reduces to "can we still find our session id anywhere in iTerm".
  func sessionExists() -> Bool {
    guard !sessionID.isEmpty else { return false }
    // "is processing" is true while a child process is attached to the
    // session's pty. Once the TUI exits, iTerm may keep the session frame
    // visible ("Session Ended" banner) but marks it not processing. That
    // is the signal we want for the quit assertion.
    let r = osa(scriptTargetingSession(body: "if is processing of s then return \"yes\""))
    return r == "yes"
  }

  // MARK: - Visual screenshot capture
  //
  // Saves a PNG of the TUI's iTerm window at the current frame. Useful
  // for visual regression. Text captures via `contents of s` miss
  // color, cell width, alt-screen vs main-screen confusion, and font
  // rendering. Screenshots catch those.
  //
  // The capture requires Screen Recording permission on the terminal
  // that runs lmd-qa. Granted once in System Settings > Privacy.
  //
  // Flow:
  //   1. Select our window inside iTerm so it is topmost within iTerm.
  //   2. Activate iTerm so its topmost window is the system frontmost.
  //   3. Read the window bounds.
  //   4. Sleep briefly so macOS paints the reordered window.
  //   5. screencapture -R x,y,w,h <path>.
  //
  // We write to `<outputDir>/<label>.png` and create the dir if absent.
  @discardableResult
  func screenshot(to path: String) -> Bool {
    guard !sessionID.isEmpty else { return false }

    // One osascript round-trip that selects the window, activates iTerm,
    // and returns the window's screen-coord bounds. Doing this in one
    // call avoids race conditions between activation and bounds read.
    let boundsRaw = osa("""
      tell application "iTerm"
        activate
        repeat with w in windows
          repeat with t in tabs of w
            repeat with s in sessions of t
              try
                if (id of s as string) is "\(sessionID)" then
                  tell w to select
                  set b to bounds of w
                  return (item 1 of b as string) & "," & (item 2 of b as string) & "," & (item 3 of b as string) & "," & (item 4 of b as string)
                end if
              end try
            end repeat
          end repeat
        end repeat
        return ""
      end tell
      """)
    let parts = boundsRaw.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
    guard parts.count == 4 else { return false }
    let (x1, y1, x2, y2) = (parts[0], parts[1], parts[2], parts[3])
    let width = x2 - x1
    let height = y2 - y1
    guard width > 0, height > 0 else { return false }

    // Give macOS time to repaint the window-order change before capture.
    Thread.sleep(forTimeInterval: 0.3)

    let dir = (path as NSString).deletingLastPathComponent
    try? FileManager.default.createDirectory(
      atPath: dir, withIntermediateDirectories: true
    )

    // -x suppresses the shutter sound. -R takes a rect (x,y,width,height).
    // Coordinate origin for -R is top-left of the primary display in
    // logical points, matching the bounds AppleScript returns.
    sh(["screencapture", "-x", "-R\(x1),\(y1),\(width),\(height)", path])
    return FileManager.default.fileExists(atPath: path)
  }
}

// MARK: Coverage tracking

var exercisedLabels: [String: Set<String>] = [:]  // driver name -> labels exercised
var currentDriverName: String = ""
// Active driver reference so helpers (printScreen, assertions) can invoke
// driver-specific extensions. Only the iterm driver currently uses this
// for PNG screenshot capture.
var currentDriver: TUIDriver?
var failures = 0

// When non-nil, every printScreen call also writes a PNG to this
// directory if the active driver supports it. Set via TUIQA_SCREENSHOT_DIR
// or via `--screenshot-dir`. iTerm-only; other drivers no-op.
var screenshotDir: String?

func recordLabel(_ label: String) {
  exercisedLabels[currentDriverName, default: []].insert(label)
}

func assertContains(_ label: String, _ pattern: String, in screen: String) {
  recordLabel(label)
  if screen.contains(pattern) {
    say("  PASS [\(currentDriverName)/\(label)]: found \"\(pattern)\"")
  } else {
    say("  FAIL [\(currentDriverName)/\(label)]: expected \"\(pattern)\"")
    say("screen follows")
    say(screen)
    say("end screen")
    failures += 1
  }
}

func assertNotContains(_ label: String, _ pattern: String, in screen: String) {
  recordLabel(label)
  if screen.contains(pattern) {
    say("  FAIL [\(currentDriverName)/\(label)]: unexpected \"\(pattern)\"")
    say("screen follows")
    say(screen)
    say("end screen")
    failures += 1
  } else {
    say("  PASS [\(currentDriverName)/\(label)]: absent \"\(pattern)\"")
  }
}

func assertSessionGone(_ label: String, _ driver: TUIDriver) {
  recordLabel(label)
  // Poll for up to 3 seconds. iTerm's `is processing` flag and tmux's
  // has-session check can both lag a fraction of a second behind the
  // actual process exit, especially with the shell's `; exit` wrapper
  // under iTerm. A tight poll beats racy one-shot checks without making
  // the happy path slower than necessary.
  let deadline = Date().addingTimeInterval(3.0)
  while Date() < deadline {
    if !driver.sessionExists() {
      say("  PASS [\(currentDriverName)/\(label)]: process exited cleanly")
      return
    }
    settle(0.1)
  }
  say("  FAIL [\(currentDriverName)/\(label)]: process still running after quit")
  failures += 1
}

func printScreen(_ label: String, _ screen: String) {
  say("\n=== screen capture [\(currentDriverName)]: \(label) ===")
  say(screen)
  say("===\n")

  // Visual screenshot side-effect. Only the iTerm driver captures real
  // pixels. Text captures already cover every other driver.
  if let dir = screenshotDir, let iterm = currentDriver as? ITermDriver {
    let safe = label.replacingOccurrences(of: "/", with: "_")
    let path = "\(dir)/\(currentDriverName)-\(safe).png"
    _ = iterm.screenshot(to: path)
  }
}

// MARK: lmd-tui QA

func qaLmdTui(driver: TUIDriver, binDir: String) {
  say("\n========================================")
  say(" QA [\(driver.name)]: lmd-tui")
  say("========================================")

  driver.start("\(binDir)/lmd-tui")
  settle(1.5)
  var screen = driver.capture()
  printScreen("launch", screen)
  assertContains("lmd-tui:launch:topbar",   "lmd", in: screen)
  assertContains("lmd-tui:launch:tab-list", "monitor",   in: screen)
  assertContains("lmd-tui:launch:tab-list", "library",   in: screen)
  assertNotContains("lmd-tui:launch:crash-free", "exception", in: screen)
  assertNotContains("lmd-tui:launch:crash-free", "Exception", in: screen)

  // Tab 2: Library
  driver.sendKey("2"); settle(0.5)
  screen = driver.capture()
  printScreen("tab2/library", screen)
  assertContains("lmd-tui:tab:switch-by-number", "library", in: screen)
  assertContains("lmd-tui:library:active",       "library", in: screen)

  // Keyboard navigation
  driver.sendKey("j"); settle(0.3)
  driver.sendKey("j"); settle(0.3)
  driver.sendKey("k"); settle(0.3)
  screen = driver.capture()
  assertNotContains("lmd-tui:library:keyboard-nav", "exception", in: screen)

  // Search: filter the list down by typing a query. We type "q" to try
  // to match models whose name or slug contains "q" (e.g. Qwen*). After
  // Enter the filter commits and the header switches from
  //   `MODELS  10 · sort:name · / search · s sort`
  // to `MODELS  N/10 · "q" · esc clear`. The `esc clear` hint only appears
  // while a query is active, so we use it as the "filtered" signal.
  driver.sendKey("/"); settle(0.3)
  driver.sendKey("q"); settle(0.2)
  driver.sendKey("Enter"); settle(0.3)
  screen = driver.capture()
  assertContains("lmd-tui:library:search-filter", "esc clear", in: screen)

  // Clear search by entering search then Escape. The `esc clear` hint
  // goes away and the `/ search · s sort` hint returns.
  driver.sendKey("/"); settle(0.2)
  driver.sendKey("Escape"); settle(0.3)
  screen = driver.capture()
  assertContains("lmd-tui:library:search-clear", "/ search", in: screen)

  // Sort: press `s` to cycle sort mode once. Screen should show sort:size.
  driver.sendKey("s"); settle(0.3)
  screen = driver.capture()
  assertContains("lmd-tui:library:sort-cycle", "sort:size", in: screen)
  // Cycle through the remaining modes and back to name.
  driver.sendKey("s"); settle(0.2)
  driver.sendKey("s"); settle(0.2)

  // Mouse click in library list
  driver.mouseClick(col: 60, row: 10); settle(0.3)
  screen = driver.capture()
  assertNotContains("lmd-tui:library:mouse-click", "exception", in: screen)

  // Mouse scroll (wheel down + up)
  driver.mouseScrollDown(col: 60, row: 15, times: 3); settle(0.3)
  driver.mouseScrollUp(col: 60, row: 15, times: 3); settle(0.3)
  screen = driver.capture()
  assertNotContains("lmd-tui:library:mouse-scroll", "exception", in: screen)

  // Hover + scroll: verify region-scoped scroll does not crash
  driver.mouseHoverAndScroll(col: 60, row: 15, scrollDown: true, times: 2); settle(0.3)
  screen = driver.capture()
  assertNotContains("lmd-tui:library:hover-scroll", "exception", in: screen)

  // Tab 3: Bench
  driver.sendKey("3"); settle(0.5)
  screen = driver.capture()
  printScreen("tab3/bench", screen)
  assertContains("lmd-tui:bench:active", "bench", in: screen)
  driver.mouseScrollDown(col: 60, row: 20, times: 2); settle(0.3)
  screen = driver.capture()
  assertNotContains("lmd-tui:bench:mouse-scroll", "exception", in: screen)

  // Tab 4: Events
  driver.sendKey("4"); settle(0.5)
  screen = driver.capture()
  printScreen("tab4/events", screen)
  assertContains("lmd-tui:events:active", "events", in: screen)
  driver.mouseScrollDown(col: 60, row: 20, times: 2); settle(0.3)
  screen = driver.capture()
  assertNotContains("lmd-tui:events:mouse-scroll", "exception", in: screen)

  // Tab 1: Monitor
  driver.sendKey("1"); settle(0.5)
  screen = driver.capture()
  printScreen("tab1/monitor", screen)
  assertContains("lmd-tui:monitor:active",         "monitor", in: screen)
  assertContains("lmd-tui:monitor:thermal-section", "THERMAL", in: screen)
  driver.mouseScrollDown(col: 60, row: 20, times: 3); settle(0.3)
  screen = driver.capture()
  assertNotContains("lmd-tui:monitor:mouse-scroll", "exception", in: screen)

  // Tab cycling via Tab key. 4 tabs now (monitor, library, bench,
  // events), so 4 Tabs cycles all the way back to monitor. Go 1 Tab to
  // land on library and assert, then one more round to confirm full
  // cycle returns to monitor's THERMAL.
  driver.sendKey("Tab"); settle(0.25)
  screen = driver.capture()
  assertContains("lmd-tui:tab:switch-by-cycle", "library", in: screen)
  for _ in 0..<3 { driver.sendKey("Tab"); settle(0.25) }
  screen = driver.capture()
  assertContains("lmd-tui:tab:full-cycle-back-to-first", "THERMAL", in: screen)

  // Unbound key
  driver.sendKey("~"); settle(0.3)
  screen = driver.capture()
  assertNotContains("lmd-tui:resilience:unbound-key", "exception", in: screen)

  // Rapid burst
  for _ in 0..<20 { driver.sendKey("Tab") }
  settle(0.5)
  screen = driver.capture()
  assertNotContains("lmd-tui:resilience:rapid-keystrokes", "exception", in: screen)

  // Quit. Force monitor tab first so we're not on library (which has its
  // own key handling that could complicate `q`).
  driver.sendKey("1"); settle(0.3)
  driver.sendKey("q"); settle(1.5)
  assertSessionGone("lmd-tui:quit:clean-exit", driver)

  driver.kill()
}

// MARK: Coverage enforcement

func loadRequiredLabels(from path: String) -> [String]? {
  guard let contents = try? String(contentsOfFile: path, encoding: .utf8) else {
    return nil
  }
  return contents.split(separator: "\n").compactMap { line in
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    if trimmed.isEmpty || trimmed.hasPrefix("#") { return nil }
    return trimmed
  }
}

// Coverage check runs once per driver. Every required label must appear in
// every driver's exercisedLabels set. Any missing label under any driver
// counts as a failure.
func enforceCoverage(requiredLabels: [String], scopeFilter: String?, driverNames: [String]) -> Int {
  let required = scopeFilter.map { prefix in
    requiredLabels.filter { $0.hasPrefix("\(prefix):") }
  } ?? requiredLabels
  var deficit = 0

  say("\n========================================")
  say(" Coverage report")
  say("========================================")
  say("  required labels: \(required.count)")
  say("  drivers:         \(driverNames.joined(separator: ", "))")

  for dn in driverNames {
    let ex = exercisedLabels[dn] ?? []
    let missing = required.filter { !ex.contains($0) }.sorted()
    let exerciseCount = required.count - missing.count
    say("")
    say("  [\(dn)] exercised: \(exerciseCount) / \(required.count)")
    if !missing.isEmpty {
      say("    missing:")
      for label in missing { say("      * \(label)") }
      deficit += missing.count
    }

    let manifestSet = Set(required)
    let scopePrefix = scopeFilter.map { "\($0):" } ?? ""
    let orphaned = ex
      .filter { scopePrefix.isEmpty || $0.hasPrefix(scopePrefix) }
      .filter { !manifestSet.contains($0) }
      .sorted()
    if !orphaned.isEmpty {
      say("    orphaned (not in manifest):")
      for label in orphaned { say("      * \(label)") }
      deficit += orphaned.count
    }
  }

  if deficit == 0 {
    say("\n  [coverage] PASS (100% on every driver)")
  } else {
    say("\n  [coverage] FAIL: \(deficit) violation(s)")
  }
  return deficit
}

// MARK: Entry point

let env = ProcessInfo.processInfo.environment
let binDir = env["LMD_BINARY_DIR"] ?? ".build/release"
let coverageFile = env["TUIQA_COVERAGE_FILE"] ?? "Tests/Fixtures/tuiqa-coverage.txt"
screenshotDir = env["TUIQA_SCREENSHOT_DIR"]

var positional: [String] = []
var driverSpec: String? = nil
var checkCoverage = true
var argsIter = CommandLine.arguments.dropFirst().makeIterator()
while let arg = argsIter.next() {
  switch arg {
  case "--no-coverage":
    checkCoverage = false
  case "--driver":
    driverSpec = argsIter.next()
  case "--screenshot-dir":
    screenshotDir = argsIter.next()
  case "--help", "-h":
    say("""
      tuiqa: interactive TUI QA driver
      Usage: tuiqa [lmd-tui|all] [--driver tmux|pty|iterm|comma-list] [--no-coverage] [--screenshot-dir <path>]

      Environment:
        LMD_BINARY_DIR        where release binaries live (default .build/release)
        TUIQA_COVERAGE_FILE   coverage manifest (default Tests/Fixtures/tuiqa-coverage.txt)
        TUIQA_SCREENSHOT_DIR  write PNG screenshots at each printScreen (iterm driver only)
      """)
    exit(0)
  default:
    positional.append(arg)
  }
}
let target = positional.first ?? "all"

let driverNames: [String]
if let spec = driverSpec {
  driverNames = spec.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
} else {
  driverNames = ["tmux", "pty", "iterm"]
}

func makeDriver(_ name: String) -> TUIDriver? {
  switch name {
  case "tmux":  return TmuxDriver()
  case "pty":   return PTYDriver()
  case "iterm": return ITermDriver()
  default:
    say("unknown driver: \(name)")
    return nil
  }
}

var scopeFilter: String?
switch target {
case "lmd-tui": scopeFilter = "lmd-tui"
case "all":     scopeFilter = nil
default:
  say("unknown target: \(target)")
  exit(2)
}

for dn in driverNames {
  guard let driver = makeDriver(dn) else {
    failures += 1
    continue
  }
  currentDriver = driver
  currentDriverName = dn

  switch target {
  case "lmd-tui", "all":
    qaLmdTui(driver: driver, binDir: binDir)
  default:
    break
  }
}

var coverageDeficit = 0
if checkCoverage {
  if let required = loadRequiredLabels(from: coverageFile) {
    coverageDeficit = enforceCoverage(requiredLabels: required, scopeFilter: scopeFilter, driverNames: driverNames)
  } else {
    say("\n[coverage] WARN: manifest not found at \(coverageFile). Skipping coverage check.")
  }
}

say("")
if failures == 0 && coverageDeficit == 0 {
  let total = exercisedLabels.values.reduce(0) { $0 + $1.count }
  say("[tui-qa] PASSED (\(total) label-runs across \(driverNames.count) driver(s))")
} else {
  say("[tui-qa] FAILED. assertions=\(failures) coverage=\(coverageDeficit)")
  exit(1)
}
