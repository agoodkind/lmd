//
//  Screen.swift
//  SwiftLMTUI
//
//  Created by Alex Goodkind <alex@goodkind.io> on 2026-04-18.
//  Copyright © 2026
//

import AppLogger
import Foundation

private let log = AppLogger.logger(category: "Screen")

// MARK: - Screen lifecycle

/// Terminal-side setup and teardown helpers.
///
/// The TUI runs in an alternate screen buffer with the cursor hidden,
/// line wrapping disabled, and SGR mouse reporting enabled. ``Screen``
/// packages those one-time side effects so callers never type the
/// escapes by hand.
public enum Screen {
  // MARK: - Enter / leave alternate screen

  /// Switch into the alternate screen buffer, hide the cursor, disable
  /// wrap, enable SGR mouse reporting, and clear the viewport.
  public static func enter(enableMouse: Bool = true) {
    var seq = Ansi.altOn + Ansi.hideCursor + Ansi.wrapOff
    if enableMouse {
      seq += Ansi.mouseOn
    }
    seq += "\u{001B}[2J" + Ansi.home
    write(seq)
  }

  /// Restore everything ``enter`` changed.
  public static func leave() {
    let seq = Ansi.mouseOff + Ansi.showCursor + Ansi.wrapOn + Ansi.altOff + Ansi.reset
    write(seq)
  }

  /// Install `leave()` as an `atexit` handler so the terminal is
  /// restored on any exit path including crashes and signals.
  public static func installRestoreOnExit() {
    atexit {
      Screen.leave()
    }
  }

  // MARK: - Size

  /// Terminal size as (rows, columns).
  public static func currentSize(fallback: (rows: Int, cols: Int) = (rows: 40, cols: 120)) -> (rows: Int, cols: Int) {
    // `stty size` prints "rows cols" to stdout. We pin its stdin to /dev/tty
    // explicitly because callers routinely put inherited stdin into raw or
    // non-blocking mode, which breaks stty's ioctl probing.
    let task = Process()
    task.launchPath = "/bin/stty"
    task.arguments = ["size"]
    let pipe = Pipe()
    task.standardOutput = pipe
    task.standardError = FileHandle(forWritingAtPath: "/dev/null")
    if let tty = FileHandle(forReadingAtPath: "/dev/tty") {
      task.standardInput = tty
    }
    do {
      try task.run()
      task.waitUntilExit()
    } catch {
      return fallback
    }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    guard let s = String(data: data, encoding: .utf8) else { return fallback }
    let parts = s.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ")
    guard parts.count == 2, let r = Int(parts[0]), let c = Int(parts[1]) else { return fallback }
    return (r, c)
  }

  // MARK: - Write primitives

  /// Write raw bytes to stdout. Uses POSIX write() so a closed PTY (e.g. VHS
  /// teardown) returns EPIPE silently instead of throwing NSFileHandleOperationException.
  public static func write(_ s: String) {
    guard let data = s.data(using: .utf8) else { return }
    data.withUnsafeBytes { ptr in
      guard var base = ptr.baseAddress else { return }
      var remaining = ptr.count
      while remaining > 0 {
        let n = Darwin.write(STDOUT_FILENO, base, remaining)
        if n <= 0 {
          if errno == EINTR || errno == EAGAIN { continue }
          return
        }
        base = base.advanced(by: n)
        remaining -= n
      }
    }
  }

  /// Clear the entire viewport.
  public static func clearViewport() {
    write("\u{001B}[2J" + Ansi.home)
  }

  /// Write a string anchored at a 1-based `row`. Appends a line clear so
  /// old content in the same row is overwritten.
  public static func writeRow(_ row: Int, _ text: String) {
    write(Ansi.move(row, 1) + text + Ansi.clearLine)
  }

  // MARK: - Resize observation

  /// Install a SIGWINCH handler that calls `onResize` whenever the
  /// terminal window is resized.
  public static func onResize(_ handler: @escaping @Sendable () -> Void) -> DispatchSourceSignal {
    signal(SIGWINCH, SIG_IGN)
    let src = DispatchSource.makeSignalSource(signal: SIGWINCH)
    src.setEventHandler(handler: handler)
    src.resume()
    return src
  }
}
