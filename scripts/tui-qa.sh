#!/bin/sh
# tui-qa.sh -- interactive TUI QA driver using tmux.
#
# Launches each TUI binary in a headless tmux session, sends keystrokes and
# mouse events, captures the live screen after each action, and asserts that
# expected content is (or is not) present.
#
# Usage:
#   bash scripts/tui-qa.sh              # run full suite
#   bash scripts/tui-qa.sh swiftlmui    # run only swiftlmui
#   bash scripts/tui-qa.sh swifttop     # run only swifttop
#
# Requirements: tmux, .build/release/{swiftlmui,swifttop}

set -e

COLS=120
ROWS=40
SESSION="tui-qa-$$"
FAILURES=0
TARGET="${1:-all}"
BINDIR="${SWIFTBENCH_BINARY_DIR:-.build/release}"

# ---------------------------------------------------------------------------
# Cleanup

cleanup() {
  tmux kill-session -t "$SESSION" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

# ---------------------------------------------------------------------------
# Session lifecycle

start_session() {
  local binary="$1"
  tmux kill-session -t "$SESSION" 2>/dev/null || true
  tmux new-session -d -s "$SESSION" -x "$COLS" -y "$ROWS"
  tmux send-keys -t "$SESSION" "$binary" Enter
}

kill_session() {
  tmux kill-session -t "$SESSION" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Input helpers

send_key() {
  tmux send-keys -t "$SESSION" "$1" ""
}

settle() {
  sleep "${1:-0.5}"
}

capture() {
  tmux capture-pane -t "$SESSION" -p
}

# Send SGR mouse events directly into the running process via tmux.
# The TUI enables SGR mouse reporting on startup.
# These sequences match what a real terminal sends.
#
# SGR press:   ESC [ < Cb ; Cx ; Cy M
# SGR release: ESC [ < Cb ; Cx ; Cy m
#
# Button codes:
#   0  = left click
#   64 = wheel up
#   65 = wheel down

ESC=$(printf '\033')

mouse_click() {
  local col="${1:-60}" row="${2:-20}"
  printf '%s' "${ESC}[<0;${col};${row}M" | tmux load-buffer -
  tmux paste-buffer -t "$SESSION"
  sleep 0.05
  printf '%s' "${ESC}[<0;${col};${row}m" | tmux load-buffer -
  tmux paste-buffer -t "$SESSION"
}

mouse_scroll_down() {
  local col="${1:-60}" row="${2:-20}" times="${3:-3}"
  local i=0
  while [ "$i" -lt "$times" ]; do
    printf '%s' "${ESC}[<65;${col};${row}M" | tmux load-buffer -
    tmux paste-buffer -t "$SESSION"
    sleep 0.05
    i=$((i+1))
  done
}

mouse_scroll_up() {
  local col="${1:-60}" row="${2:-20}" times="${3:-3}"
  local i=0
  while [ "$i" -lt "$times" ]; do
    printf '%s' "${ESC}[<64;${col};${row}M" | tmux load-buffer -
    tmux paste-buffer -t "$SESSION"
    sleep 0.05
    i=$((i+1))
  done
}

# ---------------------------------------------------------------------------
# Assertion helpers

assert_contains() {
  local label="$1" pattern="$2" screen="$3"
  if printf '%s' "$screen" | grep -qF "$pattern"; then
    printf '  PASS [%s]: found "%s"\n' "$label" "$pattern"
  else
    printf '  FAIL [%s]: expected "%s"\n' "$label" "$pattern"
    printf '--- screen ---\n%s\n--------------\n' "$screen"
    FAILURES=$((FAILURES+1))
  fi
}

assert_not_contains() {
  local label="$1" pattern="$2" screen="$3"
  if printf '%s' "$screen" | grep -qF "$pattern"; then
    printf '  FAIL [%s]: unexpected "%s"\n' "$label" "$pattern"
    printf '--- screen ---\n%s\n--------------\n' "$screen"
    FAILURES=$((FAILURES+1))
  else
    printf '  PASS [%s]: absent "%s"\n' "$label" "$pattern"
  fi
}

assert_session_gone() {
  local label="$1"
  if tmux has-session -t "$SESSION" 2>/dev/null; then
    printf '  FAIL [%s]: process still running\n' "$label"
    FAILURES=$((FAILURES+1))
  else
    printf '  PASS [%s]: process exited cleanly\n' "$label"
  fi
}

print_screen() {
  local label="$1" screen="$2"
  printf '\n=== screen capture: %s ===\n%s\n===\n\n' "$label" "$screen"
}

# ---------------------------------------------------------------------------
# swiftlmui QA

qa_swiftlmui() {
  echo ""
  echo "========================================"
  echo " QA: swiftlmui"
  echo "========================================"

  start_session "$BINDIR/swiftlmui"
  settle 1.5
  screen=$(capture)
  print_screen "launch" "$screen"
  assert_contains     "launch/topbar"    "swiftlmui"   "$screen"
  assert_contains     "launch/tab-list"  "monitor"     "$screen"
  assert_contains     "launch/tab-list"  "library"     "$screen"
  assert_not_contains "launch/crash"     "exception"   "$screen"
  assert_not_contains "launch/crash"     "Exception"   "$screen"

  # tab 2: Library (keyboard)
  echo ""
  echo "  -- tab 2: library --"
  send_key "2"; settle 0.5
  screen=$(capture)
  print_screen "tab2/library" "$screen"
  assert_contains     "tab2/active"      "library"     "$screen"
  assert_not_contains "tab2/crash"       "exception"   "$screen"

  # j/k keyboard navigation
  send_key "j"; settle 0.3
  send_key "j"; settle 0.3
  screen=$(capture)
  assert_not_contains "nav-dn/crash"     "exception"   "$screen"
  send_key "k"; settle 0.3
  screen=$(capture)
  assert_not_contains "nav-up/crash"     "exception"   "$screen"

  # mouse click in the library list area
  echo ""
  echo "  -- mouse click in library list --"
  mouse_click 60 10
  settle 0.3
  screen=$(capture)
  assert_not_contains "mouse-click/crash" "exception"  "$screen"

  # mouse scroll in library list
  echo ""
  echo "  -- mouse scroll in library --"
  mouse_scroll_down 60 15 3
  settle 0.3
  screen=$(capture)
  assert_not_contains "mouse-scroll-dn/crash" "exception" "$screen"

  mouse_scroll_up 60 15 3
  settle 0.3
  screen=$(capture)
  assert_not_contains "mouse-scroll-up/crash" "exception" "$screen"

  # tab 3: Chat
  echo ""
  echo "  -- tab 3: chat --"
  send_key "3"; settle 0.5
  screen=$(capture)
  print_screen "tab3/chat" "$screen"
  assert_contains     "tab3/chat"        "chat"        "$screen"
  assert_not_contains "tab3/crash"       "exception"   "$screen"

  # type into composer
  send_key "h"; send_key "e"; send_key "l"; send_key "l"; send_key "o"
  settle 0.3
  screen=$(capture)
  assert_contains     "chat/compose"     "hello"       "$screen"

  # mouse click in chat input area
  mouse_click 60 35
  settle 0.2
  screen=$(capture)
  assert_not_contains "chat/mouse-click-crash" "exception" "$screen"

  # /clear
  send_key "/"; send_key "c"; send_key "l"; send_key "e"; send_key "a"; send_key "r"
  send_key "Enter"
  settle 0.3
  screen=$(capture)
  assert_not_contains "chat/cleared"     "hello"       "$screen"

  # tab 4: Bench
  echo ""
  echo "  -- tab 4: bench --"
  send_key "4"; settle 0.5
  screen=$(capture)
  print_screen "tab4/bench" "$screen"
  assert_contains     "tab4/bench"       "bench"       "$screen"
  assert_not_contains "tab4/crash"       "exception"   "$screen"

  # mouse scroll in bench view
  mouse_scroll_down 60 20 2
  settle 0.3
  screen=$(capture)
  assert_not_contains "bench/scroll-crash" "exception" "$screen"

  # tab 5: Events
  echo ""
  echo "  -- tab 5: events --"
  send_key "5"; settle 0.5
  screen=$(capture)
  print_screen "tab5/events" "$screen"
  assert_contains     "tab5/events"      "events"      "$screen"
  assert_not_contains "tab5/crash"       "exception"   "$screen"

  mouse_scroll_down 60 20 2
  settle 0.3
  screen=$(capture)
  assert_not_contains "events/scroll-crash" "exception" "$screen"

  # tab 1: Monitor
  echo ""
  echo "  -- tab 1: monitor --"
  send_key "1"; settle 0.5
  screen=$(capture)
  print_screen "tab1/monitor" "$screen"
  assert_contains     "tab1/monitor"     "monitor"     "$screen"
  assert_contains     "monitor/thermal"  "THERMAL"     "$screen"

  # mouse scroll in monitor view
  mouse_scroll_down 60 20 3
  settle 0.3
  screen=$(capture)
  assert_not_contains "monitor/scroll-crash" "exception" "$screen"

  # tab key cycling
  echo ""
  echo "  -- tab key cycling --"
  send_key "Tab"; settle 0.4
  send_key "Tab"; settle 0.4
  send_key "Tab"; settle 0.4
  screen=$(capture)
  assert_not_contains "tab-cycle/crash"  "exception"   "$screen"

  # unbound key (should be ignored gracefully)
  send_key "~"; settle 0.3
  screen=$(capture)
  assert_not_contains "unbound/crash"    "exception"   "$screen"

  # quit
  echo ""
  echo "  -- quit --"
  send_key "q"; settle 0.8
  assert_session_gone "quit/exit"
}

# ---------------------------------------------------------------------------
# swifttop QA

qa_swifttop() {
  echo ""
  echo "========================================"
  echo " QA: swifttop"
  echo "========================================"

  start_session "$BINDIR/swifttop"
  settle 1.5
  screen=$(capture)
  print_screen "launch" "$screen"
  assert_contains     "launch/topbar"    "swiftbench"  "$screen"
  assert_contains     "launch/thermal"   "THERMAL"     "$screen"
  assert_not_contains "launch/crash"     "exception"   "$screen"
  assert_not_contains "launch/crash"     "Exception"   "$screen"

  # keyboard scroll
  echo ""
  echo "  -- keyboard scroll --"
  send_key "j"; settle 0.3
  send_key "j"; settle 0.3
  screen=$(capture)
  assert_not_contains "scroll-dn/crash"  "exception"   "$screen"

  send_key "k"; settle 0.3
  screen=$(capture)
  assert_not_contains "scroll-up/crash"  "exception"   "$screen"

  send_key "g"; settle 0.3
  screen=$(capture)
  assert_contains     "top/thermal"      "THERMAL"     "$screen"

  send_key "G"; settle 0.3
  screen=$(capture)
  assert_not_contains "bot/crash"        "exception"   "$screen"

  send_key "g"; settle 0.2
  send_key "Space"; settle 0.3
  screen=$(capture)
  assert_not_contains "pgdn/crash"       "exception"   "$screen"

  # mouse scroll
  echo ""
  echo "  -- mouse scroll --"
  send_key "g"; settle 0.2

  mouse_scroll_down 60 20 5
  settle 0.4
  screen=$(capture)
  print_screen "after-mouse-scroll-dn" "$screen"
  assert_not_contains "mouse-scroll-dn/crash" "exception" "$screen"

  mouse_scroll_up 60 20 5
  settle 0.4
  screen=$(capture)
  assert_not_contains "mouse-scroll-up/crash" "exception" "$screen"
  assert_contains     "mouse-scroll-up/top"   "THERMAL"   "$screen"

  # mouse click
  echo ""
  echo "  -- mouse click --"
  mouse_click 60 20
  settle 0.3
  screen=$(capture)
  assert_not_contains "mouse-click/crash" "exception"  "$screen"

  # unbound key
  send_key "~"; settle 0.3
  screen=$(capture)
  assert_not_contains "unbound/crash"    "exception"   "$screen"

  # quit
  echo ""
  echo "  -- quit --"
  send_key "q"; settle 0.8
  assert_session_gone "quit/exit"
}

# ---------------------------------------------------------------------------
# Run

case "$TARGET" in
  swiftlmui) qa_swiftlmui ;;
  swifttop)  qa_swifttop  ;;
  *)
    qa_swiftlmui
    qa_swifttop
    ;;
esac

echo ""
if [ "$FAILURES" -eq 0 ]; then
  echo "[tui-qa] PASSED"
else
  echo "[tui-qa] FAILED: $FAILURES assertion(s) failed"
  exit 1
fi
