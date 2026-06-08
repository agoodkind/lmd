#
#  Makefile
#  lmd
#
#  Thin aliases around the Swift-owned development tool.
#

TUIST ?= tuist
TARGET ?=
CONFIG ?= Debug
LMD_DEV := TUIST="$(TUIST)" swift Tools/lmd-dev.swift

.PHONY: help toolchain preflight build debug test test-integration lint format install install-debug \
        uninstall clean run-serve run-tui run-bench stop-serve start-serve restart-serve \
        test-daemon-up test-daemon-down test-daemon-status \
        snapshot-update log-audit log-smoke tui-qa smoke video-smoke \
        sign notarize notary-setup dist ci-import-cert ci-sign ci-notarize \
        release-tag push-tag github-release cleanup-keychain

help:
	@$(LMD_DEV) help

toolchain:
	@$(LMD_DEV) toolchain

preflight:
	@$(LMD_DEV) preflight

build:
	@$(LMD_DEV) build $(CONFIG)

debug:
	@$(LMD_DEV) debug

test:
	@$(LMD_DEV) test

test-integration:
	@$(LMD_DEV) test-integration

clean:
	@$(LMD_DEV) clean

install:
	@$(LMD_DEV) install $(CONFIG)

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

log-audit:
	@$(LMD_DEV) log-audit

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

lint:
	@$(LMD_DEV) lint

format:
	@$(LMD_DEV) format
