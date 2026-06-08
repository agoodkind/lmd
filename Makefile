#
#  Makefile
#  lmd
#
#  Consumer of swift-mk: build, test, clean, lint, fmt, and check route through
#  swift-mk so the gates run over lmd's own sources. The dev tool drives the
#  actual compile and the developer-only subcommands.
#

TUIST ?= tuist
TARGET ?=
CONFIG ?= Debug
LMD_DEV = SWIFT_MK_BIN="$(SWIFT_MK_BIN)" TUIST="$(TUIST)" swift Tools/lmd-dev.swift

# swift-mk owns build/test/clean/lint/fmt/check; the dev tool runs the compile.
SWIFT_MK_MODULES := swift-build.mk
SWIFT_MK_OWN_RUN := 1
SWIFT_BUILD_CMD = $(LMD_DEV) build $(CONFIG)
SWIFT_TEST_CMD = $(LMD_DEV) test
SWIFT_CLEAN_CMD = $(LMD_DEV) clean
SWIFT_DEPLOY_CMD = $(LMD_DEV) install $(CONFIG)
SWIFT_LOG_AUDIT_CMD = $(LMD_DEV) log-audit
SWIFT_FORMAT_TARGETS := Sources Tests Tools
SWIFTLINT_TARGETS := Sources Tests Tools
SWIFTCHECK_EXTRA_TARGETS := Sources Tests Tools

include bootstrap.mk

.PHONY: toolchain preflight debug test-integration install-debug \
        uninstall run-serve run-tui run-bench stop-serve start-serve restart-serve \
        test-daemon-up test-daemon-down test-daemon-status \
        snapshot-update log-smoke tui-qa smoke video-smoke \
        sign notarize notary-setup dist ci-import-cert ci-sign ci-notarize \
        release-tag push-tag github-release cleanup-keychain

toolchain:
	@$(LMD_DEV) toolchain

preflight:
	@$(LMD_DEV) preflight

debug:
	@$(LMD_DEV) debug

test-integration:
	@$(LMD_DEV) test-integration

install-debug:
	@CONFIG=Debug $(LMD_DEV) install Debug

uninstall:
	@$(LMD_DEV) uninstall

start-serve:
	@$(LMD_DEV) start-serve

stop-serve:
	@$(LMD_DEV) stop-serve

restart-serve:
	@$(LMD_DEV) restart-serve

test-daemon-up:
	@$(LMD_DEV) test-daemon up

test-daemon-down:
	@$(LMD_DEV) test-daemon down

test-daemon-status:
	@$(LMD_DEV) test-daemon status

run-serve:
	@$(LMD_DEV) run-serve

run-tui:
	@$(LMD_DEV) run-tui

run-bench:
	@$(LMD_DEV) run-bench

smoke:
	@$(LMD_DEV) smoke

video-smoke:
	@$(LMD_DEV) video-smoke

snapshot-update:
	@$(LMD_DEV) snapshot-update

tui-qa:
	@$(LMD_DEV) tui-qa $(TARGET)

log-smoke:
	@$(LMD_DEV) log-smoke

notary-setup:
	@$(LMD_DEV) notary-setup

sign:
	@$(LMD_DEV) sign

notarize:
	@$(LMD_DEV) notarize

dist:
	@CONFIG=Release $(LMD_DEV) dist

ci-import-cert:
	@$(LMD_DEV) ci-import-cert

ci-sign:
	@$(LMD_DEV) ci-sign

ci-notarize:
	@$(LMD_DEV) ci-notarize

release-tag:
	@$(LMD_DEV) release-tag

push-tag:
	@$(LMD_DEV) push-tag

github-release:
	@$(LMD_DEV) github-release

cleanup-keychain:
	@$(LMD_DEV) cleanup-keychain
