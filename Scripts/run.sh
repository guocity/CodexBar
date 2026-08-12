#!/bin/bash
set -euo pipefail

# Launch the existing app bundle only. This never builds, packages, or tests.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/CodexBar.app"

if [[ ! -x "$APP/Contents/MacOS/CodexBar" ]]; then
    echo "CodexBar.app is not built yet. Build it once before using this script." >&2
    exit 1
fi

pkill -x CodexBar 2>/dev/null || true
env -u CODEXBAR_DISABLE_KEYCHAIN_ACCESS -u CODEXBAR_KEYCHAIN_NO_UI open -n "$APP"
