#
#  Makefile
#  lmd
#
#  Consumer of swift-mk: build, test, clean, lint, fmt, and check route through
#  swift-mk so the gates run over lmd's own sources. The dev tool drives the
#  actual compile and the developer-only subcommands.
#

TARGET ?=
CONFIG ?= Debug
LMD_DEV = SWIFT_MK_BIN="$(SWIFT_MK_BIN)" swift Tools/lmd-dev.swift

# swift-mk owns build/test/clean/lint/fmt/check; the dev tool runs the compile.
SWIFT_MK_MODULES := swift-build.mk swift-release.mk
SWIFT_MK_OWN_RUN := 1
SWIFT_BUILD_CMD = $(LMD_DEV) build $(CONFIG)
SWIFT_TEST_CMD = $(LMD_DEV) test
SWIFT_CLEAN_CMD = $(LMD_DEV) clean
SWIFT_DEPLOY_CMD = $(LMD_DEV) install $(CONFIG)
SWIFT_FORMAT_TARGETS := Sources Tests Tools
SWIFTLINT_TARGETS := Sources Tests Tools
SWIFTCHECK_EXTRA_TARGETS := Sources Tests Tools

# CI default; release.yml overrides it as a make variable, and the export is
# what carries the override into the lmd-dev child process.
LMD_ENABLE_CCACHE ?= 0
export LMD_ENABLE_CCACHE

# Release artifacts for the shared _release.yml pipeline: build, post-build
# codesign, then lmd-dev's own notarization (bare CLI zips cannot be stapled,
# so the shared workflow runs with notarize disabled), then the zip into dist/.
SWIFT_MK_RELEASE_BUILD_CMD := $(MAKE) SWIFT_MK_SKIP_FETCH=1 build CONFIG=Release && $(MAKE) SWIFT_MK_SKIP_FETCH=1 ci-sign && $(MAKE) SWIFT_MK_SKIP_FETCH=1 ci-notarize && cp Products/lmd-*.zip dist/

include bootstrap.mk

.PHONY: toolchain preflight debug test-integration install-debug \
        uninstall run-serve run-tui run-bench stop-serve start-serve restart-serve \
        test-daemon-up test-daemon-down test-daemon-status \
        snapshot-update log-smoke tui-qa smoke video-smoke \
        sign notarize notary-setup dist ci-sign ci-notarize

# lmd-dev shells out to $(SWIFT_MK_BIN) from these entry points, so each one
# must build the binary first; without this a fresh checkout (CI) ran lmd-dev
# before any swift-mk existed.
toolchain preflight ci-sign: swift-mk-bin

# Every dev-tool entry point that compiles or runs a product routes through the
# gated `build` chokepoint first, so the lint gates cannot be bypassed by
# invoking the dev tool's own compile paths. The dev tool's inner build is
# incremental after the gated build. `ci-sign`/`ci-notarize` stay un-gated
# because SWIFT_MK_RELEASE_BUILD_CMD already runs the gated build first.
debug install-debug test-integration snapshot-update \
        run-serve run-tui run-bench smoke video-smoke tui-qa \
        sign notarize dist: build

toolchain:
	@"$(SWIFT_MK_BIN)" toolchain version

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

ci-sign:
	@$(LMD_DEV) ci-sign

ci-notarize:
	@$(LMD_DEV) ci-notarize
