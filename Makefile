SHELL := /bin/bash

override ROOT := $(realpath $(dir $(lastword $(MAKEFILE_LIST))))
override DIST := $(ROOT)/dist
override GUEST_DIST := $(DIST)/guest
override APP := $(DIST)/app.noindex/Try Omarchy.app
override BUILD_CACHE := $(ROOT)/scripts/build-cache.py
override BUILD_STATE := $(ROOT)/.build/state
override DOWNLOAD_CACHE := $(ROOT)/.build/downloads
RELEASE_SIGN_IDENTITY ?= Developer ID Application: Eduardo Martinez (RZC79MPD34)
RELEASE_NOTARY_PROFILE ?= try-omarchy
VERSION ?=
export VERSION RELEASE_SIGN_IDENTITY RELEASE_NOTARY_PROFILE
DEVELOPMENT_SIGN_IDENTITY ?= auto
PACKAGE_SIGN_IDENTITY ?= $(RELEASE_SIGN_IDENTITY)
PACKAGE_NOTARY_PROFILE ?= $(RELEASE_NOTARY_PROFILE)
FORCE ?= 0
TEST_JOBS ?= 4

SHELL_TESTS := network-helper qemu-networking qemu-port-forwarding run-qemu-gpu \
  qemu-usb-passthrough qemu-monitor-ready
SHELL_TEST_TARGETS := $(addprefix test-shell-,$(SHELL_TESTS))

.DEFAULT_GOAL := help
.PHONY: help doctor test guest guest-package refresh runtime firmware app build run run-ephemeral reset version-preflight package package-preflight release release-preflight publish clean clean-all clean-guest
.PHONY: test-all test-contracts test-guest test-swift test-shell $(SHELL_TEST_TARGETS)
.PHONY: test-upstream test-guest-install e2e

help:
	@printf '%s\n' \
	  'Try Omarchy — native macOS build commands' \
	  '' \
	  '  make doctor         Check the local toolchain' \
	  '  make test           Run native and guest contract tests' \
	  '  make test TEST_JOBS=1  Run test suites serially for debugging' \
	  '  make test-upstream  Check the guest package against the current Omarchy (network)' \
	  '  make test-guest-install  Install, upgrade and remove the guest package (Docker, network)' \
	  '  make e2e            Boot a disposable VM in the app and check it end to end' \
	  '  make build          Build only changed guest, runtime, and app inputs' \
	  '  make build FORCE=1  Rebuild every component (the guest takes the newest Omarchy edge)' \
	  '  make refresh        Rebuild the factory from the latest Omarchy edge, then build' \
	  '  make run            Build the app from existing artifacts and open it' \
	  '                      Automatically select a stable development certificate' \
	  '  make run DEVELOPMENT_SIGN_IDENTITY="Apple Development: ..."' \
	  '                      Choose a certificate when several are available' \
	  '  make package        Create a signed and notarized distribution DMG' \
	  '  make release        Choose a version, tag, and build a notarized DMG (latest factory)' \
	  '  make release VERSION=vX.Y.Z  Choose the version without prompting' \
	  '  make release FORCE=1  Rebuild the factory even if it matches upstream' \
	  '  make publish        Push the release tag and attach the DMG and image to its GitHub draft' \
	  '' \
	  'Component builds:' \
	  '  make guest          Ensure dist/guest (try-omarchy package and factory disk) is current (Docker)' \
	  '  make guest-package  Rebuild only the try-omarchy package; the next app build bundles it' \
	  '  make runtime        Ensure macos/.build/qemu-gpu-runtime is current' \
	  '  make firmware       Stage the UEFI firmware from the pinned QEMU source' \
	  '  make app            Ensure every artifact and the app are current' \
	  '' \
	  'Storage:' \
	  '  make run-ephemeral  Run without retaining VM changes' \
	  '  make reset          Open the confirmed factory-reset flow' \
	  '  make clean          Remove all project builds and build caches' \
	  '  make clean-all      Also remove VM data and stale temporary files'

doctor:
	@[[ "$$(uname -s)" == Darwin ]] || { echo 'error: macOS is required' >&2; exit 1; }
	@[[ "$$(uname -m)" == arm64 ]] || { echo 'error: an Apple Silicon Mac is required' >&2; exit 1; }
	@major=$$(sw_vers -productVersion | cut -d. -f1); (( major >= 15 )) || { echo 'error: macOS 15 or newer is required' >&2; exit 1; }
	@for tool in curl docker pkg-config python3 swift xcrun; do command -v "$$tool" >/dev/null || { echo "error: $$tool is required" >&2; exit 1; }; done
	@docker info >/dev/null 2>&1 || { echo 'error: Docker is installed but not running' >&2; exit 1; }
	@printf 'Toolchain ready: %s (%s)\n' "$$(sw_vers -productVersion)" "$$(uname -m)"

test:
	@[[ "$(TEST_JOBS)" =~ ^[1-9][0-9]*$$ ]] || { echo 'error: TEST_JOBS must be a positive integer' >&2; exit 1; }
	@$(MAKE) --no-print-directory -j$(TEST_JOBS) test-all

# Start Swift early; shell integration suites consume its helper binary. Each
# suite owns its temporary state, but SwiftPM has a single build directory.
test-all: test-swift test-contracts test-guest test-shell

test-contracts:
	@PYTHONDONTWRITEBYTECODE=1 python3 "$(ROOT)/tests/native-client-sdr-white.py"
	@PYTHONDONTWRITEBYTECODE=1 python3 "$(ROOT)/macos/Tests/test-hda-recovery.py"
	@PYTHONDONTWRITEBYTECODE=1 python3 "$(ROOT)/macos/Tests/test-network-identity.py"
	@PYTHONDONTWRITEBYTECODE=1 python3 "$(ROOT)/macos/Tests/test-libslirp-icmp.py"
	@PYTHONDONTWRITEBYTECODE=1 python3 "$(ROOT)/macos/Tests/test-cocoa-pinch.py"
	@PYTHONDONTWRITEBYTECODE=1 python3 "$(ROOT)/macos/Tests/test-cocoa-scroll.py"
	@PYTHONDONTWRITEBYTECODE=1 python3 "$(ROOT)/macos/Tests/test-cocoa-iso-keyboard.py"
	@PYTHONDONTWRITEBYTECODE=1 python3 "$(ROOT)/macos/Tests/test-cocoa-minimum-guest-size.py"
	@PYTHONDONTWRITEBYTECODE=1 python3 "$(ROOT)/macos/Tests/test-cocoa-no-app-nap.py"
	@PYTHONDONTWRITEBYTECODE=1 python3 "$(ROOT)/macos/Tests/test-cocoa-notch.py"
	@PYTHONDONTWRITEBYTECODE=1 python3 "$(ROOT)/macos/Tests/test-audio-runtime-patches.py"
	@PYTHONDONTWRITEBYTECODE=1 python3 "$(ROOT)/macos/Tests/test-cocoa-injected-text.py"
	@PYTHONDONTWRITEBYTECODE=1 python3 "$(ROOT)/macos/Tests/test-cocoa-keyboard-focus.py"
	@PYTHONDONTWRITEBYTECODE=1 python3 "$(ROOT)/macos/Tests/test-hvf-memory-reclaim.py"
	@PYTHONDONTWRITEBYTECODE=1 python3 "$(ROOT)/macos/Tests/test-hvf-mapped-sections.py"
	@PYTHONDONTWRITEBYTECODE=1 python3 "$(ROOT)/macos/Tests/test-runtime-capabilities.py"
	@PYTHONDONTWRITEBYTECODE=1 python3 "$(ROOT)/macos/Tests/test-virtio-pinch.py"
	@PYTHONDONTWRITEBYTECODE=1 python3 "$(ROOT)/tests/test-build-cache.py"
	@PYTHONDONTWRITEBYTECODE=1 python3 "$(ROOT)/tests/test-factory-freshness.py"
	@PYTHONDONTWRITEBYTECODE=1 python3 "$(ROOT)/tests/test-profile-process.py"
	@PYTHONDONTWRITEBYTECODE=1 python3 "$(ROOT)/tests/test-development-sign-identity.py"
	@PYTHONDONTWRITEBYTECODE=1 python3 "$(ROOT)/tests/test-app-version.py"
	@PYTHONDONTWRITEBYTECODE=1 python3 "$(ROOT)/tests/test-release.py"
	@PYTHONDONTWRITEBYTECODE=1 python3 "$(ROOT)/tests/test-publish.py"
	@PYTHONDONTWRITEBYTECODE=1 python3 "$(ROOT)/tests/test-package-dmg.py"
	@PYTHONDONTWRITEBYTECODE=1 python3 "$(ROOT)/tests/test-split-factory-image.py"
	@PYTHONDONTWRITEBYTECODE=1 python3 "$(ROOT)/tests/test-pack-app-icon.py"
	@$(ROOT)/macos/Tests/macos-compatibility.test.sh
	@$(ROOT)/macos/Tests/runtime-relocation.test.sh

test-guest:
	@PYTHONDONTWRITEBYTECODE=1 python3 "$(ROOT)/guest/package/tests/test_hdr_build.py"
	@PYTHONDONTWRITEBYTECODE=1 python3 "$(ROOT)/guest/package/tests/test_hdr_integration.py"
	@PYTHONDONTWRITEBYTECODE=1 python3 "$(ROOT)/guest/package/tests/test_hdr_policy.py"
	@PYTHONDONTWRITEBYTECODE=1 python3 "$(ROOT)/guest/package/tests/test_package.py"

# The package's contracts with the Omarchy the factory installs today.
test-upstream:
	@rm -rf "$(ROOT)/.build/upstream-omarchy"
	@"$(ROOT)/guest/tests/fetch-upstream.sh" "$(ROOT)/.build/upstream-omarchy"
	@OMARCHY_UPSTREAM_ROOT="$(ROOT)/.build/upstream-omarchy" PYTHONDONTWRITEBYTECODE=1 \
	  python3 "$(ROOT)/guest/package/tests/test_upstream.py"

# A disposable VM in the built app, first boot to second boot (tests/e2e/run.sh).
E2E_ARGS ?=
e2e:
	@"$(ROOT)/tests/e2e/run.sh" --app "$(APP)" $(E2E_ARGS)

# The package installed, upgraded from BASE (default: the main branch) and
# removed against Omarchy's live repositories, in the guest builder image.
BASE ?= main
test-guest-install:
	@"$(ROOT)/guest/tests/package-check.sh" --base "$(BASE)" --cache "$(ROOT)/.build/pacman-cache"

test-swift:
	@mkdir -p $(ROOT)/macos/.build/module-cache/swift $(ROOT)/macos/.build/module-cache/clang
	@cd $(ROOT)/macos && SWIFT_MODULECACHE_PATH=$(ROOT)/macos/.build/module-cache/swift CLANG_MODULE_CACHE_PATH=$(ROOT)/macos/.build/module-cache/clang swift test --disable-sandbox

test-shell: $(SHELL_TEST_TARGETS)

$(SHELL_TEST_TARGETS): test-shell-%: test-swift
	@bash "$(ROOT)/macos/Tests/$*.test.sh"

# The package and the factory disk are cached separately: a package change
# rebuilds the package in seconds, and the app delivers it to every VM.
guest: guest-package
	@OMARCHY_FORCE_BUILD="$(FORCE)" "$(BUILD_CACHE)" \
	  --root "$(ROOT)" --state-dir "$(BUILD_STATE)" guest -- \
	  "$(ROOT)/guest/build.sh" --factory-only --output "$(GUEST_DIST)"

guest-package:
	@OMARCHY_FORCE_BUILD="$(FORCE)" "$(BUILD_CACHE)" \
	  --root "$(ROOT)" --state-dir "$(BUILD_STATE)" guest-package -- \
	  "$(ROOT)/guest/package/build.sh" --output "$(GUEST_DIST)/packages"

# Pinned downloads (QEMU and its dependencies' sources, Homebrew bottles) are
# kept here between builds and checksum-verified on every use.
runtime:
	@OMARCHY_FORCE_BUILD="$(FORCE)" OMARCHY_DOWNLOAD_CACHE="$(DOWNLOAD_CACHE)" "$(BUILD_CACHE)" \
	  --root "$(ROOT)" --state-dir "$(BUILD_STATE)" runtime -- \
	  "$(ROOT)/macos/build-qemu-gpu-runtime.sh"

firmware:
	@[[ -f "$(ROOT)/macos/.build/firmware/edk2-aarch64-code.fd" && "$(FORCE)" != 1 ]] || \
	  OMARCHY_DOWNLOAD_CACHE="$(DOWNLOAD_CACHE)" "$(ROOT)/macos/stage-uefi-firmware.sh"

app: guest runtime firmware
	@identity=$$(python3 "$(ROOT)/macos/development-sign-identity.py" "$(DEVELOPMENT_SIGN_IDENTITY)") || exit 1; \
	  OMARCHY_FORCE_BUILD="$(FORCE)" \
	  OMARCHY_CODESIGN_IDENTITY="$$identity" \
	  "$(BUILD_CACHE)" \
	  --root "$(ROOT)" --state-dir "$(BUILD_STATE)" app -- \
	  "$(ROOT)/macos/build-app.sh" --guest-dir "$(GUEST_DIST)"

build: doctor app
	@printf 'Build output: %s\n' "$(APP)"
	@python3 "$(ROOT)/scripts/factory-freshness.py" --root "$(ROOT)"

# The factory is cached by its inputs, not by upstream: rebuild it from what
# Omarchy's edge repositories serve now.
refresh:
	@$(MAKE) --no-print-directory guest FORCE=1
	@$(MAKE) --no-print-directory build

run: app
	@$(ROOT)/macos/open-qemu-gpu.sh

run-ephemeral: app
	@$(ROOT)/macos/open-qemu-gpu.sh --ephemeral

reset: app
	@$(ROOT)/macos/open-qemu-gpu.sh --reset-storage

version-preflight:
	@python3 "$(ROOT)/scripts/app_version.py" --root "$(ROOT)" --require-release

package-preflight: version-preflight
	@[[ "$(PACKAGE_SIGN_IDENTITY)" == "Developer ID Application:"* ]] || { echo 'error: PACKAGE_SIGN_IDENTITY must be a Developer ID Application identity' >&2; exit 1; }
	@[[ -n "$(strip $(PACKAGE_NOTARY_PROFILE))" ]] || { echo 'error: PACKAGE_NOTARY_PROFILE must name a notarytool keychain profile' >&2; exit 1; }

package: package-preflight
	@$(MAKE) --no-print-directory guest runtime firmware
	@$(ROOT)/macos/build-app.sh \
	  --configuration production \
	  --dmg \
	  --guest-dir "$(GUEST_DIST)" \
	  --sign-identity "$(PACKAGE_SIGN_IDENTITY)" \
	  --notarize-profile "$(PACKAGE_NOTARY_PROFILE)"

release-preflight:
	@[[ "$(RELEASE_SIGN_IDENTITY)" == "Developer ID Application:"* ]] || { echo 'error: RELEASE_SIGN_IDENTITY must be a Developer ID Application identity' >&2; exit 1; }
	@[[ -n "$(strip $(RELEASE_NOTARY_PROFILE))" ]] || { echo 'error: RELEASE_NOTARY_PROFILE must name a notarytool keychain profile' >&2; exit 1; }

release: export RELEASE_MAKE := $(MAKE)
release: export RELEASE_FORCE := $(FORCE)
release: release-preflight
	@python3 "$(ROOT)/scripts/release.py" --root "$(ROOT)"

# Pushes the built release's tag, then uploads to the draft release with that
# tag (or creates one). Publishing the draft stays manual.
publish:
	@python3 "$(ROOT)/scripts/publish.py" --root "$(ROOT)"

clean:
	@echo 'Removing repository build output and caches...'
	@rm -rf -- \
	  "$(DIST)" \
	  "$(ROOT)/.build" \
	  "$(ROOT)/guest/.work" \
	  "$(ROOT)/macos/.build" \
	  "$(ROOT)/macos/.swiftpm"
	@find "$(ROOT)" -type d \( -name __pycache__ -o -name .pytest_cache \) \
	  -prune -exec rm -rf -- {} +
	@set -e; if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then \
	  while IFS= read -r container; do \
	    [[ -z "$$container" ]] || docker container rm "$$container" >/dev/null; \
	  done < <(docker container ls -aq --filter ancestor=try-omarchy-guest-builder); \
	  while IFS= read -r volume; do \
	    [[ -z "$$volume" ]] || docker volume rm "$$volume" >/dev/null; \
	  done < <(docker volume ls -q --filter label=dev.tryomarchy.role=guest-work); \
	  while IFS= read -r volume; do \
	    [[ -z "$$volume" ]] || docker volume rm "$$volume" >/dev/null; \
	  done < <(docker volume ls -q --filter label=dev.tryomarchy.role=upstream-work); \
	  docker image rm -f try-omarchy-guest-builder try-omarchy-upstream-builder >/dev/null 2>&1 || true; \
	  echo 'Removed Try Omarchy Docker builder image and guest-work volumes.'; \
	else \
	  echo 'Docker is unavailable; skipped project Docker cache cleanup.' >&2; \
	fi

clean-all:
	@[[ "$$(uname -s)" == Darwin ]] || { echo 'error: make clean-all requires macOS' >&2; exit 1; }
	@pgrep -f 'omarchy-[q]emu|omarchy-[d]mg|Try Omarchy[.]app/Contents/' >/dev/null 2>&1; status=$$?; \
	if (( status == 0 )); then \
	  echo 'error: Try Omarchy or one of its build tools is running; close it before make clean-all' >&2; \
	  exit 1; \
	elif (( status != 1 )); then \
	  echo 'error: could not safely inspect running processes' >&2; \
	  exit 1; \
	fi
	@confirmation=''; \
	if ! { \
	  printf '%s\n%s' \
	    'This permanently deletes all Try Omarchy builds, caches, VM disks, and app state.' \
	    'Type clean-all to continue: ' >/dev/tty && \
	  IFS= read -r confirmation </dev/tty; \
	}; then \
	  echo 'error: make clean-all requires an interactive terminal' >&2; \
	  exit 1; \
	fi; \
	[[ "$$confirmation" == clean-all ]] || { echo 'Cleanup cancelled.' >&2; exit 1; }
	@$(MAKE) --no-print-directory clean
	@user_home=$$(python3 -c 'import os,pwd; print(pwd.getpwuid(os.getuid()).pw_dir)'); \
	  [[ "$$user_home" == /* && "$$user_home" != / ]] || { echo 'error: could not resolve a safe user home' >&2; exit 1; }; \
	  app_support="$$user_home/Library/Application Support/Try Omarchy"; \
	  cache="$$user_home/Library/Caches/dev.tryomarchy.native"; \
	  preferences="$$user_home/Library/Preferences/dev.tryomarchy.native.plist"; \
	  saved_state="$$user_home/Library/Saved Application State/dev.tryomarchy.native.savedState"; \
	  development_cache="$$user_home/Library/Caches/dev.tryomarchy.native.development"; \
	  development_preferences="$$user_home/Library/Preferences/dev.tryomarchy.native.development.plist"; \
	  development_saved_state="$$user_home/Library/Saved Application State/dev.tryomarchy.native.development.savedState"; \
	  echo "Removing persistent VM disks and app state from $$app_support..."; \
	  rm -rf -- "$$app_support" "$$cache" "$$preferences" "$$saved_state" \
	    "$$development_cache" "$$development_preferences" "$$development_saved_state"
	@user_id=$$(id -u); \
	  find /private/tmp -maxdepth 1 -user "$$user_id" \
	    \( -name 'omarchy-qemu-source-build.*' \
	       -o -name 'omarchy-qemu-gpu-runtime.*' \
	       -o -name 'omarchy-qemu-gpu.??????' \
	       -o -name 'omarchy-qemu-storage-test.??????' \
	       -o -name 'omarchy-dmg.*' \) \
	    -exec rm -rf -- {} +; \
	  user_tmp=$$(getconf DARWIN_USER_TEMP_DIR); \
	  [[ "$$user_tmp" == /* && "$$user_tmp" != / && "$$user_tmp" != /private/tmp/ ]] || { echo 'error: could not resolve a safe user temporary directory' >&2; exit 1; }; \
	  find "$$user_tmp" -maxdepth 1 -user "$$user_id" \
	    \( -name 'omarchy-qemu-request-*' \
	       -o -name 'omarchy-qemu-path-*' \
	       -o -name 'omarchy-audio-route-tests.*' \
	       -o -name 'try-omarchy-space-estimate-*' \) \
	    -exec rm -rf -- {} +
	@echo 'Try Omarchy deep cleanup complete.'

clean-guest: clean
	@echo 'make clean-guest is now an alias for make clean.'
