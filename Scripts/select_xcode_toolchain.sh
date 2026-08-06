#!/usr/bin/env bash
# shellcheck shell=bash
#
# Ensures `swift build` runs under a full Xcode toolchain.
#
# `swift build` (SwiftPM) cannot run under the CommandLineTools toolchain on this setup —
# `swift-package` fails to load `BuildServerProtocol.framework`. A full Xcode (stable or beta)
# is required. This helper exports a working `DEVELOPER_DIR` and prepends the matching Swift
# toolchain's bin dir to PATH, so bare `swift`/`xcrun` invocations resolve to it.
#
# Resolution order (so both Xcode.app and Xcode-beta.app work):
#   1. An explicit `DEVELOPER_DIR` the caller already set, if it's a full Xcode.
#   2. The active `xcode-select -p`, if it points at a full Xcode (not CommandLineTools).
#   3. A discovered Xcode under /Applications — stable first, then beta, then any.

# A full Xcode's developer dir ends in `.app/Contents/Developer` and ships `usr/bin/xcodebuild`
# (CommandLineTools has neither). `swift` itself lives in the toolchain, found via `xcrun --find`.
codexbar_developer_dir_is_full_xcode() {
  local dir="$1"
  [[ "$dir" == *.app/Contents/Developer && -x "$dir/usr/bin/xcodebuild" ]]
}

# Exports DEVELOPER_DIR and puts the toolchain's `swift` on PATH so bare `swift build` uses it.
codexbar_apply_developer_dir() {
  local dir="$1"
  export DEVELOPER_DIR="$dir"
  local swift_bin
  swift_bin="$(DEVELOPER_DIR="$dir" /usr/bin/xcrun --find swift 2>/dev/null || true)"
  if [[ -n "$swift_bin" && -x "$swift_bin" ]]; then
    export PATH="$(dirname "$swift_bin"):$PATH"
  fi
}

codexbar_select_xcode_toolchain() {
  # 1) Honor a caller-provided full-Xcode DEVELOPER_DIR (e.g. `DEVELOPER_DIR=…Xcode-beta… make start`).
  if [[ -n "${DEVELOPER_DIR:-}" ]] && codexbar_developer_dir_is_full_xcode "${DEVELOPER_DIR}"; then
    codexbar_apply_developer_dir "${DEVELOPER_DIR}"
    return 0
  fi

  # 2) Use the active selection if it is a full Xcode.
  local selected
  selected="$(xcode-select -p 2>/dev/null || true)"
  if codexbar_developer_dir_is_full_xcode "${selected}"; then
    codexbar_apply_developer_dir "${selected}"
    return 0
  fi

  # 3) Discover an Xcode under /Applications (stable preferred, then beta, then any other).
  local candidate developer
  for candidate in /Applications/Xcode.app /Applications/Xcode-beta.app /Applications/Xcode*.app; do
    developer="${candidate}/Contents/Developer"
    if codexbar_developer_dir_is_full_xcode "${developer}"; then
      codexbar_apply_developer_dir "${developer}"
      echo "==> Using Xcode toolchain: ${DEVELOPER_DIR}"
      return 0
    fi
  done

  echo "WARN: No full Xcode found (only CommandLineTools?). 'swift build' will likely fail." >&2
  echo "WARN: Install Xcode or run 'sudo xcode-select -s /Applications/Xcode.app' (or set DEVELOPER_DIR)." >&2
  return 0
}
