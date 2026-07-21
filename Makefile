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
# The MLX metallib build needs the on-demand Metal toolchain. lmd-dev ensures it
# in-code: buildMetallib and preflight run `swift-mk toolchain download-component
# MetalToolchain` unconditionally, on every metallib path (build, test,
# test-integration, smoke, preflight). That replaces the old swift-mk preflight
# rail, whose `xcrun --find metal` check false-passed when the binary was present
# but the toolchain component was not.
SWIFT_BUILD_CMD = $(LMD_DEV) build $(CONFIG)
SWIFT_TEST_CMD = $(LMD_DEV) test
SWIFT_CLEAN_CMD = $(LMD_DEV) clean
SWIFT_DEPLOY_CMD = $(LMD_DEV) install $(CONFIG)
# The build generate hook builds the vendored SwiftLM chat binary and its metallib
# against lmd's resolved MLX, staged into Products/Build/$(CONFIG)/swiftlm for install
# and release. swift-build.mk runs this before the SwiftPM/metallib compile, and the
# subcommand's own stamp guard skips the rebuild when SwiftLM and the MLX pins are
# unchanged.
SWIFT_GENERATE_CMD = $(LMD_DEV) build-swiftlm $(CONFIG)
# The dev tool is now an SPM package under Tools/, so Tools/.build holds the
# vendored swift-makefile checkout (thousands of files). Lint owned sources by an
# explicit file list that prunes any .build, never the bare Tools directory, so
# swiftlint does not recurse the vendored tree and overflow git check-ignore.
SWIFT_SOURCE_ROOTS := Sources Tests Tools/lmd-dev
SWIFT_OWNED_SWIFT_FILES := $(shell find $(SWIFT_SOURCE_ROOTS) -path '*/.build/*' -prune -o -name '*.swift' -print)
SWIFT_PACKAGE_MANIFESTS := Package.swift Tools/Package.swift Tools/lmd-dev.swift
SWIFT_MK_EXCLUDE_PATHS := ^Tools/.build/

SWIFT_FORMAT_TARGETS := $(SWIFT_OWNED_SWIFT_FILES) $(SWIFT_PACKAGE_MANIFESTS)
SWIFTLINT_TARGETS := $(SWIFT_FORMAT_TARGETS)
SWIFTLINT_EXCLUDE_PATHS := $(SWIFT_MK_EXCLUDE_PATHS)
SWIFTCHECK_EXTRA_TARGETS := $(SWIFT_FORMAT_TARGETS)
SWIFTCHECK_EXTRA_EXCLUDE_PATHS := $(SWIFT_MK_EXCLUDE_PATHS)

# swift-mk owns post-build signing of the bare CLI binaries the xcconfig override
# cannot reach. lmd declares the built products, the resource-bundle directory, and
# the bundle-id prefix; after `build`, the engine signs each artifact with
# <prefix>.<basename> through the canonical codesign channel, but only when an
# identity is set (CI), so a local unsigned Debug build is untouched. CONFIG-scoped
# so the paths match whichever configuration was built.
SWIFT_MK_SIGN_PRODUCTS := Products/Build/$(CONFIG)/lmd Products/Build/$(CONFIG)/lmd-serve Products/Build/$(CONFIG)/swiftlm/SwiftLM
SWIFT_MK_SIGN_BUNDLES_DIR := Products/Build/$(CONFIG)
SWIFT_MK_SIGN_IDENTIFIER_PREFIX := io.goodkind.lmd

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
