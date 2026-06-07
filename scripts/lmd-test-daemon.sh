#!/usr/bin/env bash
#
# lmd-test-daemon.sh
#
# Stand up an ISOLATED lmd-serve LaunchAgent next to the production daemon for
# live testing, without ever touching production. The test agent uses its own
# launchd label, its own control and host Mach services, its own port, and its
# own data dir, so the production daemon on :5400 keeps running untouched.
#
# It renders deploy/io.goodkind.lmd.serve.test.plist.template against the
# worktree's freshly built lmd-serve, bootstraps it under the caller's gui
# domain, and waits for /health. The battery throttle is disabled in the
# template so the hard-level admission halt can never refuse requests.
#
# Usage:
#   scripts/lmd-test-daemon.sh up        render, bootstrap, wait for /health
#   scripts/lmd-test-daemon.sh down      bootout and clean up
#   scripts/lmd-test-daemon.sh status    health probe plus launchctl print
#   scripts/lmd-test-daemon.sh restart   kickstart -k to pick up a rebuilt binary
#   scripts/lmd-test-daemon.sh logs      follow the test daemon stderr log
#
# Environment overrides:
#   LMD_TEST_PORT       test broker port (default 5401)
#   LMD_TEST_LABEL      launchd label (default io.goodkind.lmd.serve.test)
#   LMD_TEST_DATA_DIR   data dir (default <repo>/.claude/tmp/lmd-test/data)
#   LMD_SWIFTLM_BINARY  SwiftLM chat binary (default: read from production plist)
#   LMD_TEST_KEEP_DATA  set to 1 so `down` keeps the data dir
#   LMD_TEST_BATTERY_THROTTLE_PCT / _MILD_PCT / _RESUME_PCT
#                       battery thresholds for the test daemon. Default 0/1/2
#                       disables the PowerMonitor so the hard admission halt
#                       never interrupts a test run; raise them (keeping
#                       hard < mild < resume) to exercise the real throttle.
#

set -euo pipefail

readonly PROD_LABEL="io.goodkind.lmd.serve"
readonly PROD_PORT="5400"

readonly TEST_LABEL="${LMD_TEST_LABEL:-io.goodkind.lmd.serve.test}"
readonly TEST_CONTROL_SERVICE="io.goodkind.lmd.control.test"
readonly TEST_HOST_SERVICE="io.goodkind.lmd.host.test"
readonly TEST_PORT="${LMD_TEST_PORT:-5401}"
readonly GUI_DOMAIN="gui/$(id -u)"
readonly HEALTH_TIMEOUT_SECONDS=30

# Battery thresholds for the rendered test daemon. The defaults disable the
# PowerMonitor (engage<=0) so the hard admission halt never interrupts a test run
# on battery. Override to exercise the real throttle (keep hard < mild < resume).
readonly TEST_BATTERY_THROTTLE_PCT="${LMD_TEST_BATTERY_THROTTLE_PCT:-0}"
readonly TEST_BATTERY_MILD_PCT="${LMD_TEST_BATTERY_MILD_PCT:-1}"
readonly TEST_BATTERY_RESUME_PCT="${LMD_TEST_BATTERY_RESUME_PCT:-2}"

# OTLP export for the test daemon, baked into the rendered plist. Empty endpoint
# (the default) leaves export disabled; set OTEL_EXPORTER_OTLP_ENDPOINT in the
# caller's environment to point the broker and its spawned hosts at a collector.
readonly TEST_OTEL_ENDPOINT="${OTEL_EXPORTER_OTLP_ENDPOINT:-}"
readonly TEST_OTEL_PROTOCOL="${OTEL_EXPORTER_OTLP_PROTOCOL:-grpc}"
readonly TEST_OTEL_METRIC_INTERVAL="${OTEL_METRIC_EXPORT_INTERVAL:-2000}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR

interrupted=0

die() {
    echo "lmd-test-daemon: $*" >&2
    exit 1
}

bootout_agent() {
    launchctl bootout "$GUI_DOMAIN/$TEST_LABEL" 2>/dev/null || true
}

on_interrupt() {
    interrupted=1
    echo "lmd-test-daemon: interrupted, tearing down $TEST_LABEL" >&2
    bootout_agent
    exit 130
}

resolve_repo_root() {
    local dir="$SCRIPT_DIR"
    while [[ "$dir" != "/" ]]; do
        if [[ -f "$dir/Project.swift" && -f "$dir/AGENTS.md" ]]; then
            echo "$dir"
            return 0
        fi
        dir="$(dirname "$dir")"
    done
    return 1
}

# Prefer a Release build, fall back to Debug. The model host must sit beside the
# broker binary, since the broker resolves it as a sibling at spawn time.
resolve_serve_binary() {
    local root="$1"
    local candidate
    for candidate in \
        "$root/Products/Build/Release/lmd-serve" \
        "$root/Products/Build/Debug/lmd-serve"; do
        if [[ -x "$candidate" ]]; then
            if [[ ! -x "$(dirname "$candidate")/lmd-model-host" ]]; then
                die "found $candidate but no sibling lmd-model-host; run 'make build' first"
            fi
            echo "$candidate"
            return 0
        fi
    done
    return 1
}

# The broker checks LMD_SWIFTLM_BINARY is executable at boot even for embedding
# and video tests, so it must resolve to a real file. Read it from the installed
# production plist by default so the harness is self-configuring.
resolve_swiftlm_binary() {
    if [[ -n "${LMD_SWIFTLM_BINARY:-}" ]]; then
        echo "$LMD_SWIFTLM_BINARY"
        return 0
    fi
    local prod_plist="$HOME/Library/LaunchAgents/$PROD_LABEL.plist"
    if [[ -f "$prod_plist" ]]; then
        /usr/libexec/PlistBuddy -c "Print :EnvironmentVariables:LMD_SWIFTLM_BINARY" \
            "$prod_plist" 2>/dev/null && return 0
    fi
    return 1
}

assert_isolated() {
    [[ "$TEST_PORT" != "$PROD_PORT" ]] || die "refusing: test port equals production port $PROD_PORT"
    [[ "$TEST_LABEL" != "$PROD_LABEL" ]] || die "refusing: test label equals production label $PROD_LABEL"
}

test_data_dir() {
    local root="$1"
    echo "${LMD_TEST_DATA_DIR:-$root/.claude/tmp/lmd-test/data}"
}

render_plist() {
    local template="$1" serve_path="$2" swiftlm_binary="$3"
    local data_dir="$4" stderr_log="$5" out="$6"
    sed \
        -e "s|{{LABEL}}|$TEST_LABEL|g" \
        -e "s|{{CONTROL_SERVICE}}|$TEST_CONTROL_SERVICE|g" \
        -e "s|{{HOST_SERVICE}}|$TEST_HOST_SERVICE|g" \
        -e "s|{{LMD_SERVE_PATH}}|$serve_path|g" \
        -e "s|{{LMD_PORT}}|$TEST_PORT|g" \
        -e "s|{{LMD_DATA_DIR}}|$data_dir|g" \
        -e "s|{{LMD_SWIFTLM_BINARY}}|$swiftlm_binary|g" \
        -e "s|{{STDERR_LOG}}|$stderr_log|g" \
        -e "s|{{LMD_BATTERY_THROTTLE_PCT}}|$TEST_BATTERY_THROTTLE_PCT|g" \
        -e "s|{{LMD_BATTERY_MILD_PCT}}|$TEST_BATTERY_MILD_PCT|g" \
        -e "s|{{LMD_BATTERY_RESUME_PCT}}|$TEST_BATTERY_RESUME_PCT|g" \
        -e "s|{{OTEL_EXPORTER_OTLP_ENDPOINT}}|$TEST_OTEL_ENDPOINT|g" \
        -e "s|{{OTEL_EXPORTER_OTLP_PROTOCOL}}|$TEST_OTEL_PROTOCOL|g" \
        -e "s|{{OTEL_METRIC_EXPORT_INTERVAL}}|$TEST_OTEL_METRIC_INTERVAL|g" \
        "$template" >"$out"
}

wait_health() {
    local deadline=$(( SECONDS + HEALTH_TIMEOUT_SECONDS ))
    while (( SECONDS < deadline )); do
        if (( interrupted )); then
            return 1
        fi
        if curl -fsS -o /dev/null "http://localhost:$TEST_PORT/health" 2>/dev/null; then
            return 0
        fi
        sleep 1
    done
    return 1
}

cmd_up() {
    assert_isolated
    local root serve_path swiftlm_binary data_dir work_dir stderr_log rendered template
    root="$(resolve_repo_root)" || die "could not find repo root from $SCRIPT_DIR"
    serve_path="$(resolve_serve_binary "$root")" || die "no built lmd-serve under $root/Products/Build; run 'make build'"
    swiftlm_binary="$(resolve_swiftlm_binary)" || die "set LMD_SWIFTLM_BINARY, or install the production plist so it can be read"
    [[ -x "$swiftlm_binary" ]] || die "LMD_SWIFTLM_BINARY not executable: $swiftlm_binary"
    template="$root/deploy/io.goodkind.lmd.serve.test.plist.template"
    [[ -f "$template" ]] || die "missing template: $template"

    data_dir="$(test_data_dir "$root")"
    work_dir="$(dirname "$data_dir")"
    mkdir -p "$data_dir"
    stderr_log="$work_dir/lmd-serve.test.stderr.log"
    rendered="$work_dir/$TEST_LABEL.plist"

    render_plist "$template" "$serve_path" "$swiftlm_binary" "$data_dir" "$stderr_log" "$rendered"

    # Replace any prior instance so a stale agent never lingers, then guard the
    # health wait so an interrupt boots the agent back out.
    bootout_agent
    trap on_interrupt INT TERM
    echo "lmd-test-daemon: bootstrapping $TEST_LABEL on :$TEST_PORT"
    echo "lmd-test-daemon:   serve   = $serve_path"
    echo "lmd-test-daemon:   data    = $data_dir"
    echo "lmd-test-daemon:   swiftlm = $swiftlm_binary"
    launchctl bootstrap "$GUI_DOMAIN" "$rendered" || die "launchctl bootstrap failed for $rendered"

    if wait_health; then
        trap - INT TERM
        echo "lmd-test-daemon: healthy at http://localhost:$TEST_PORT"
        return 0
    fi
    trap - INT TERM
    echo "lmd-test-daemon: health timed out; recent stderr from $stderr_log:" >&2
    tail -n 20 "$stderr_log" 2>/dev/null || true
    die "test daemon did not become healthy"
}

cmd_down() {
    local root data_dir work_dir rendered
    root="$(resolve_repo_root)" || die "could not find repo root from $SCRIPT_DIR"
    data_dir="$(test_data_dir "$root")"
    work_dir="$(dirname "$data_dir")"
    rendered="$work_dir/$TEST_LABEL.plist"
    echo "lmd-test-daemon: booting out $TEST_LABEL"
    bootout_agent
    rm -f "$rendered"
    if [[ "${LMD_TEST_KEEP_DATA:-0}" == "1" ]]; then
        echo "lmd-test-daemon: keeping data dir $data_dir"
    else
        rm -rf "$data_dir"
    fi
    echo "lmd-test-daemon: down"
}

cmd_status() {
    echo "=== health http://localhost:$TEST_PORT/health ==="
    if curl -fsS "http://localhost:$TEST_PORT/health" 2>/dev/null; then
        echo
    else
        echo "(unreachable)"
    fi
    echo "=== launchctl print $GUI_DOMAIN/$TEST_LABEL ==="
    launchctl print "$GUI_DOMAIN/$TEST_LABEL" 2>/dev/null || echo "(not loaded)"
}

cmd_restart() {
    echo "lmd-test-daemon: kickstart -k $GUI_DOMAIN/$TEST_LABEL"
    launchctl kickstart -k "$GUI_DOMAIN/$TEST_LABEL" || die "kickstart failed"
    if wait_health; then
        echo "lmd-test-daemon: healthy at http://localhost:$TEST_PORT"
        return 0
    fi
    die "test daemon did not become healthy after restart"
}

cmd_logs() {
    local root data_dir work_dir stderr_log
    root="$(resolve_repo_root)" || die "could not find repo root from $SCRIPT_DIR"
    data_dir="$(test_data_dir "$root")"
    work_dir="$(dirname "$data_dir")"
    stderr_log="$work_dir/lmd-serve.test.stderr.log"
    [[ -f "$stderr_log" ]] || die "no log at $stderr_log"
    tail -n "${LMD_TEST_LOG_LINES:-50}" -f "$stderr_log"
}

usage() {
    echo "usage: $(basename "${BASH_SOURCE[0]}") {up|down|status|restart|logs}" >&2
}

main() {
    local cmd="${1:-}"
    case "$cmd" in
        up) cmd_up ;;
        down) cmd_down ;;
        status) cmd_status ;;
        restart) cmd_restart ;;
        logs) cmd_logs ;;
        -h | --help | help) usage ;;
        "") usage; exit 1 ;;
        *) die "unknown command: $cmd (try: up, down, status, restart, logs)" ;;
    esac
}

main "$@"
