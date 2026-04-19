#
#  Makefile
#  lmd
#
#  Shortcuts for the common dev loop and deployment of the
#  io.goodkind.lmd workstation toolkit.
#

SWIFT       ?= swift
BUILD_DIR   := .build/release
PREFIX      ?= $(HOME)/.local
BIN_DIR     := $(PREFIX)/bin
AGENT_DIR   := $(HOME)/Library/LaunchAgents
AGENT_LABEL := io.goodkind.lmd.serve
AGENT_PLIST := $(AGENT_DIR)/$(AGENT_LABEL).plist

# Every binary the package produces. Keep in sync with Package.swift's
# executable targets. Used by install, uninstall, run-*, and run-*-fg.
BINARIES := lmd lmd-serve lmd-tui lmd-bench lmd-qa

.PHONY: help build debug test lint format install uninstall clean report \
        run-serve run-tui run-bench stop-serve start-serve restart-serve \
        snapshot-update log-audit log-smoke tui-qa smoke \
        sign notarize notary-setup dist

help:
	@echo "targets:"
	@echo "  build             release build of every binary and library"
	@echo "  debug             debug build"
	@echo "  test              run the Swift test suite (unit + snapshot + integration)"
	@echo "  smoke             HTTP smoke test of lmd-serve"
	@echo "  tui-qa            interactive TUI QA (three drivers: tmux/pty/iterm)"
	@echo "  snapshot-update   regenerate TUI snapshot goldens (SNAPSHOT_UPDATE=1)"
	@echo "  log-audit         enforce Apple-native logging policy"
	@echo "  log-smoke         drive each binary + assert log coverage"
	@echo "  lint              swift-format lint + swiftlint"
	@echo "  format            swift-format in-place"
	@echo ""
	@echo "deploy:"
	@echo "  install           copy binaries to $(BIN_DIR) and load the LaunchAgent"
	@echo "  uninstall         bootout the agent and remove binaries"
	@echo "  start-serve       bootstrap the LaunchAgent if it is registered"
	@echo "  stop-serve        bootout the LaunchAgent"
	@echo "  restart-serve     kickstart -k (pick up a new binary without a full reload)"
	@echo ""
	@echo "run in foreground:"
	@echo "  run-serve         .build/release/lmd-serve"
	@echo "  run-tui           .build/release/lmd-tui"
	@echo "  run-bench         .build/release/lmd-bench"
	@echo ""
	@echo "distribution (codesign + notarize):"
	@echo "  notary-setup      one-time keychain profile setup for notarytool"
	@echo "  sign              codesign every release binary with hardened runtime"
	@echo "  notarize          submit signed binaries to Apple notary service"
	@echo "  dist              build + sign + notarize in one shot"
	@echo ""
	@echo "  clean             nuke .build"

# ------------------------------------------------------------------
# Build

build:
	$(SWIFT) build -c release

debug:
	$(SWIFT) build

test: build
	$(SWIFT) test

clean:
	rm -rf .build

# ------------------------------------------------------------------
# Install / uninstall / service lifecycle
#
# `make install` copies every binary to $(BIN_DIR), writes the
# LaunchAgent plist with the correct absolute path to lmd-serve, and
# bootstraps it under the current GUI session. After install, the
# broker is running. A reboot or logout reloads it automatically.
#
# `make uninstall` reverses the install in the same order.
#
# `make restart-serve` is what you run after rebuilding to pick up
# the new binary without a full unload/reload.

install: build
	install -d $(BIN_DIR)
	@for b in $(BINARIES); do \
	  install $(BUILD_DIR)/$$b $(BIN_DIR)/$$b; \
	  echo "  installed $(BIN_DIR)/$$b"; \
	done
	@install -d $(AGENT_DIR)
	@sed "s|{{LMD_SERVE_PATH}}|$(BIN_DIR)/lmd-serve|g" \
	    deploy/io.goodkind.lmd.serve.plist.example > $(AGENT_PLIST)
	@echo "  wrote $(AGENT_PLIST)"
	@$(MAKE) --no-print-directory start-serve

uninstall:
	@$(MAKE) --no-print-directory stop-serve
	@if [ -f $(AGENT_PLIST) ]; then rm -f $(AGENT_PLIST); echo "  removed $(AGENT_PLIST)"; fi
	@for b in $(BINARIES); do \
	  if [ -f $(BIN_DIR)/$$b ]; then rm -f $(BIN_DIR)/$$b; echo "  removed $(BIN_DIR)/$$b"; fi; \
	done

start-serve:
	@if [ ! -f $(AGENT_PLIST) ]; then \
	  echo "  no agent plist at $(AGENT_PLIST); run 'make install' first"; exit 1; \
	fi
	@launchctl bootstrap gui/$$(id -u) $(AGENT_PLIST) 2>/dev/null \
	  && echo "  bootstrapped $(AGENT_LABEL)" \
	  || echo "  $(AGENT_LABEL) was already loaded (or gui/$$(id -u) unavailable)"

stop-serve:
	@launchctl bootout gui/$$(id -u)/$(AGENT_LABEL) 2>/dev/null \
	  && echo "  booted out $(AGENT_LABEL)" \
	  || echo "  $(AGENT_LABEL) was not loaded"

restart-serve:
	@launchctl kickstart -k gui/$$(id -u)/$(AGENT_LABEL) 2>/dev/null \
	  && echo "  kickstarted $(AGENT_LABEL)" \
	  || echo "  $(AGENT_LABEL) not registered; run 'make install'"

# ------------------------------------------------------------------
# Foreground run helpers (no LaunchAgent, for dev iteration)

run-serve: build
	$(BUILD_DIR)/lmd-serve

run-tui: build
	$(BUILD_DIR)/lmd-tui

run-bench: build
	$(BUILD_DIR)/lmd-bench

# ------------------------------------------------------------------
# Test / QA / smoke

smoke: build
	./Tests/IntegrationTests/smoke-lmd-serve.sh

snapshot-update:
	@SNAPSHOT_UPDATE=1 $(SWIFT) test --filter Snapshot

tui-qa: build
	@command -v tmux >/dev/null || { echo "install: brew install tmux"; exit 1; }
	@$(BUILD_DIR)/lmd-qa $(TARGET)

# ------------------------------------------------------------------
# Log audit
#
# Enforces the rules in plan/logging-migration.md.
#   1. No print / NSLog / debugPrint / dump outside the logging module.
#   2. No direct Logger(subsystem:...) construction outside the logging module.
#   3. No `import Logging` in first-party code outside the bridge file.
#
# Exits 0 on clean, non-zero on any violation.

log-audit:
	@set -e; \
	echo "[log-audit] scanning for forbidden output calls..."; \
	if grep -rnE '(^|[^a-zA-Z_])(print|NSLog|debugPrint|dump)\(' Sources/ \
	    --include='*.swift' \
	    --exclude-dir=AppLogger ; then \
	  echo "[log-audit] FAILED: replace with log.<level>(...) or FileHandle.standardOutput.write"; \
	  exit 1; \
	fi; \
	echo "[log-audit]   output calls: OK"; \
	echo "[log-audit] scanning for direct Logger(subsystem:) construction..."; \
	if grep -rn 'Logger(subsystem:' Sources/ \
	    --include='*.swift' \
	    --exclude-dir=AppLogger ; then \
	  echo "[log-audit] FAILED: use AppLogger.logger(category:) instead"; \
	  exit 1; \
	fi; \
	echo "[log-audit]   Logger construction: OK"; \
	echo "[log-audit] scanning for swift-log direct use..."; \
	if grep -rnE '^import Logging' Sources/ \
	    --include='*.swift' \
	    --exclude-dir=AppLogger ; then \
	  echo "[log-audit] FAILED: swift-log must route through AppLogger/SwiftLogBridge"; \
	  exit 1; \
	fi; \
	echo "[log-audit]   swift-log direct use: OK"; \
	echo "[log-audit] PASSED"

log-smoke: build
	@./scripts/log-smoke.sh

# ------------------------------------------------------------------
# Distribution: codesign + notarize
#
# One-time setup:
#   1. cp config/signing.env.example config/signing.env
#   2. fill in CODE_SIGN_IDENTITY, DEVELOPMENT_TEAM, NOTARY_PROFILE
#   3. make notary-setup   (stores app-specific password in keychain)
#
# Per-release:
#   make dist
#
# `dist` = build + sign + notarize. Bare CLI binaries cannot be
# stapled, so first-launch Gatekeeper checks hit the network. Wrap
# into a .pkg if you need offline-friendly distribution.

notary-setup:
	@./scripts/notary-setup.sh

sign: build
	@./scripts/sign-binaries.sh

notarize: sign
	@./scripts/notarize.sh

dist: notarize
	@echo "[dist] artifacts: $(CURDIR)/Products/"

# ------------------------------------------------------------------
# Lint / format

lint:
	@command -v swift-format >/dev/null && swift-format lint --recursive Sources Tests || echo "swift-format not installed, skipping"
	@command -v swiftlint >/dev/null && swiftlint --quiet || echo "swiftlint not installed, skipping"

format:
	@command -v swift-format >/dev/null && swift-format format --in-place --recursive Sources Tests || echo "swift-format not installed, skipping"

# ------------------------------------------------------------------
# Report regeneration for the battery-config bench dataset.
# Path is relative to the legacy stress-test dataset location.

report:
	cd /Users/agoodkind/Sites/lm-review-stress-test && python3 analyze-configs.py
