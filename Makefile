SHELL := /bin/bash

# Keep FILTER literal, including Make expressions, shell syntax, and apostrophes.
unexport FILTER
test_filter_arg = $(if $(value FILTER),--filter '$(subst ','"'"',$(value FILTER))')

.PHONY: build check docs-list format lint release restart run start start-debug start-release stop test test-fast test-skip-build test-live test-tty

run:
	./Scripts/run.sh

start:
	./Scripts/compile_and_run.sh

start-debug:
	./Scripts/compile_and_run.sh

start-release:
	./Scripts/package_app.sh release
	pkill -x CodexBar || pkill -f CodexBar.app || true
	cd /Users/steipete/Projects/codexbar && open -n /Users/steipete/Projects/codexbar/CodexBar.app

restart: start

stop:
	pkill -x CodexBar || pkill -f CodexBar.app || true

check lint:
	./Scripts/lint.sh lint

format:
	./Scripts/lint.sh format

docs-list:
	node Scripts/docs-list.mjs

build:
	@source Scripts/select_xcode_toolchain.sh && codexbar_select_xcode_toolchain && swift build

test:
	./Scripts/test.sh

test-fast:
	./Scripts/test_fast.sh $(test_filter_arg)

test-skip-build:
	./Scripts/test_fast.sh --skip-build $(test_filter_arg)

test-tty:
	@source Scripts/select_xcode_toolchain.sh && codexbar_select_xcode_toolchain && source ./Scripts/test_environment.sh && CODEXBAR_SUPPRESS_TEST_KEYCHAIN_ACCESS=1 swift test --filter TTYIntegrationTests

test-live:
	@source Scripts/select_xcode_toolchain.sh && codexbar_select_xcode_toolchain && export CODEXBAR_ALLOW_TEST_KEYCHAIN_ACCESS=1 && source ./Scripts/test_environment.sh && LIVE_TEST=1 swift test --filter LiveAccountTests

# Fork releases only — loads .fork-release.env (your team, Developer ID, feed, Sparkle key).
# Do not use package_app.sh / upstream steipete identity from this target.
release:
	@test -f .fork-release.env || { echo "Missing .fork-release.env — copy/configure it before releasing."; exit 1; }
	./Scripts/fork-release.sh
