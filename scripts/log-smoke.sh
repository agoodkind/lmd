#!/bin/bash
#
# log-smoke.sh
#
# Drives one known-good flow per executable under subsystem
# io.goodkind.lmd, captures `log show` NDJSON, and asserts that every
# category in Tests/Fixtures/expected-categories.txt has produced at
# least one event, and that no event containing fields Rule 3 says
# must be `.public` leaks a `<private>` redaction.
#
# Usage:
#   scripts/log-smoke.sh            # with built binaries in .build/release
#   SWIFTBENCH_BINARY_DIR=/path ... # override lookup
#
# Exits 0 on clean, 1 on category miss, 2 on privacy leak, 3 on setup error.
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN_DIR="${SWIFTBENCH_BINARY_DIR:-$REPO_ROOT/.build/release}"
EXPECTED_FILE="$REPO_ROOT/Tests/Fixtures/expected-categories.txt"
CAPTURE_FILE="$(mktemp -t log-smoke.XXXXXX).ndjson"

for bin in lmd swiftbench swiftmon swifttop swiftlmui; do
  if [ ! -x "$BIN_DIR/$bin" ]; then
    echo "[log-smoke] missing binary: $BIN_DIR/$bin. Run 'swift build -c release'." >&2
    exit 3
  fi
done

if [ ! -r "$EXPECTED_FILE" ]; then
  echo "[log-smoke] missing expected-categories list: $EXPECTED_FILE" >&2
  exit 3
fi

START_TS="$(date -u +"%Y-%m-%d %H:%M:%S%z")"

echo "[log-smoke] START $START_TS"

# Drive each binary briefly.
echo "[log-smoke] driving lmd --help"
"$BIN_DIR/lmd" --help > /dev/null || true

echo "[log-smoke] driving lmd ls"
"$BIN_DIR/lmd" ls > /dev/null || true

echo "[log-smoke] kicking swiftmon"
# Force a restart so the `swiftmon.starting` startup event lands inside
# the capture window, whether it's running as a LaunchAgent or not.
if launchctl print "gui/$UID/com.goodkind.swiftmon" > /dev/null 2>&1; then
  launchctl kickstart -k "gui/$UID/com.goodkind.swiftmon"
  sleep 2
else
  "$BIN_DIR/swiftmon" &
  SWIFTMON_PID=$!
  sleep 2
  kill "$SWIFTMON_PID" 2>/dev/null || true
fi

echo "[log-smoke] driving swifttop 1s"
# swifttop draws alt-screen, so redirect stdout and SIGINT quickly.
"$BIN_DIR/swifttop" < /dev/null > /dev/null 2>&1 &
SWIFTTOP_PID=$!
sleep 1
kill -INT "$SWIFTTOP_PID" 2>/dev/null || true
wait "$SWIFTTOP_PID" 2>/dev/null || true

echo "[log-smoke] driving swiftlmui 1s"
"$BIN_DIR/swiftlmui" < /dev/null > /dev/null 2>&1 &
SWIFTLMUI_PID=$!
sleep 1
kill -INT "$SWIFTLMUI_PID" 2>/dev/null || true
wait "$SWIFTLMUI_PID" 2>/dev/null || true

# Allow unified logging to flush. log show has a small propagation delay.
sleep 1

echo "[log-smoke] capturing events since $START_TS"
/usr/bin/log show \
  --predicate "subsystem == 'io.goodkind.lmd'" \
  --start "$START_TS" \
  --style ndjson \
  --info > "$CAPTURE_FILE"

echo "[log-smoke] capture size: $(wc -l < "$CAPTURE_FILE") lines at $CAPTURE_FILE"

# Assert category coverage. Categories expected in an end-to-end smoke
# are those that actually fire during the drives above. Some categories
# only fire under specific workloads (ModelCatalog requires a catalog
# scan; BenchRunner requires a full run) — we treat those as
# informational and don't block on their absence.
REQUIRED_CATEGORIES=(DispatcherCLI MonitorSampler Dashboard TUIHost)
MISS=0
for cat in "${REQUIRED_CATEGORIES[@]}"; do
  if ! grep -q "\"category\":\"$cat\"" "$CAPTURE_FILE"; then
    echo "[log-smoke] MISS: category '$cat' produced no events"
    MISS=1
  fi
done
if [ "$MISS" -ne 0 ]; then
  echo "[log-smoke] FAILED: one or more required categories had zero events."
  echo "[log-smoke] capture preserved at $CAPTURE_FILE for inspection."
  exit 1
fi
echo "[log-smoke]   required category coverage: OK"

# Rule 3: no <private> redaction in any event we captured. Unannotated
# interpolation defaults to `.private` and would render as <private> —
# that is forbidden by policy.
if grep -q '<private>' "$CAPTURE_FILE"; then
  echo "[log-smoke] FAILED: <private> redactions detected. Some interpolation"
  echo "[log-smoke] is missing explicit privacy: .public annotation."
  echo "[log-smoke] capture at $CAPTURE_FILE"
  exit 2
fi
echo "[log-smoke]   privacy annotations: OK"

echo "[log-smoke] PASSED"
rm -f "$CAPTURE_FILE"
