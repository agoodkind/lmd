#!/bin/bash
#
# smoke-lmd-serve.sh
# Runs lmd-serve on a high random port, hits /health and /v1/models, verifies
# shape, then kills the process. Used as a quick end-to-end smoke test.
# Does NOT exercise JIT routing, which requires a real SwiftLM binary.
#
# Usage: ./Tests/IntegrationTests/smoke-lmd-serve.sh

set -euo pipefail

BIN="$(dirname "$0")/../../.build/release/lmd-serve"
PORT=$((15000 + RANDOM % 1000))

if [[ ! -x "$BIN" ]]; then
  echo "smoke-lmd-serve: binary missing at $BIN; run 'make build' first"
  exit 2
fi

echo "starting lmd-serve on :$PORT"
LMD_PORT="$PORT" "$BIN" &
PID=$!
trap 'kill "$PID" 2>/dev/null || true' EXIT

# Wait up to 30s for /health.
for i in $(seq 1 30); do
  if curl -sS -m 2 -o /tmp/smoke_hc.out -w "%{http_code}" "http://127.0.0.1:$PORT/health" 2>/dev/null | grep -q 200; then
    break
  fi
  sleep 1
  if [[ "$i" == "30" ]]; then
    echo "smoke-lmd-serve: daemon failed to come up"
    exit 1
  fi
done

echo "health OK"

# /v1/models should return a JSON object with a data array.
curl -sS -m 3 "http://127.0.0.1:$PORT/v1/models" > /tmp/smoke_models.json
python3 - <<'PY'
import json
d = json.load(open("/tmp/smoke_models.json"))
assert d.get("object") == "list", f"bad object field: {d.get('object')}"
assert isinstance(d.get("data"), list), "data is not a list"
print(f"models: {len(d['data'])}")
PY

# /swiftlmd/loaded should be empty at boot.
curl -sS -m 3 "http://127.0.0.1:$PORT/swiftlmd/loaded" > /tmp/smoke_loaded.json
python3 - <<'PY'
import json
d = json.load(open("/tmp/smoke_loaded.json"))
assert d["models"] == [], f"expected empty models, got {d['models']}"
assert d["allocated_gb"] == 0, f"expected 0 GB, got {d['allocated_gb']}"
print("loaded-models empty OK")
PY

echo "smoke-lmd-serve: PASS"
