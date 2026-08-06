#!/usr/bin/env bash
# Diagnose fork Sparkle auto-update mismatches (public key vs appcast signature).
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"

[[ -f "$ROOT/.fork-release.env" ]] || { echo "Missing .fork-release.env" >&2; exit 1; }
# shellcheck disable=SC1091
source "$ROOT/.fork-release.env"

: "${CODEXBAR_FORK_REPO:?}"
: "${CODEXBAR_SU_PUBLIC_ED_KEY:?}"
: "${CODEXBAR_FEED_URL:?}"

UPSTREAM_PUBLIC_KEY="AGCY8w5vHirVfGGDGc8Szc5iuOqupZSh9pMj/Qs67XI="
UPSTREAM_FEED="https://raw.githubusercontent.com/steipete/CodexBar/main/appcast.xml"

echo "==> Fork Sparkle feed check"
echo "    fork repo:   $CODEXBAR_FORK_REPO"
echo "    feed URL:    $CODEXBAR_FEED_URL"
echo "    fork pubkey: $CODEXBAR_SU_PUBLIC_ED_KEY"
echo

if [[ -d CodexBar.app/Contents/Info.plist ]]; then
  APP_PUBKEY=$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' CodexBar.app/Contents/Info.plist 2>/dev/null || true)
  APP_FEED=$(/usr/libexec/PlistBuddy -c 'Print :SUFeedURL' CodexBar.app/Contents/Info.plist 2>/dev/null || true)
  APP_VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' CodexBar.app/Contents/Info.plist 2>/dev/null || true)
  APP_BUILD=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' CodexBar.app/Contents/Info.plist 2>/dev/null || true)
  echo "==> Installed CodexBar.app"
  echo "    version:     ${APP_VERSION:-?} (${APP_BUILD:-?})"
  echo "    feed URL:    ${APP_FEED:-missing}"
  echo "    pubkey:      ${APP_PUBKEY:-missing}"
  if [[ -n "${APP_PUBKEY:-}" && "$APP_PUBKEY" != "$CODEXBAR_SU_PUBLIC_ED_KEY" ]]; then
    echo "    ERROR: app pubkey does not match .fork-release.env"
  fi
  if [[ -n "${APP_FEED:-}" && "$APP_FEED" != "$CODEXBAR_FEED_URL" ]]; then
    echo "    ERROR: app feed URL does not match .fork-release.env"
  fi
  echo
fi

APPCAST_TMP=$(mktemp "${TMPDIR:-/tmp}/codexbar-appcast.XXXXXX")
trap 'rm -f "$APPCAST_TMP"' EXIT
if ! curl -fsSL "$CODEXBAR_FEED_URL" -o "$APPCAST_TMP"; then
  echo "ERROR: could not fetch feed: $CODEXBAR_FEED_URL" >&2
  exit 1
fi

PARSED=$(
  python3 - <<'PY' "$APPCAST_TMP"
import sys, xml.etree.ElementTree as ET
ns = {"sparkle": "http://www.andymatuschak.org/xml-namespaces/sparkle"}
root = ET.parse(sys.argv[1]).getroot()
items = root.findall(".//item")
if not items:
    raise SystemExit("ERROR: appcast has no <item> entries")
item = items[0]
enc = item.find("enclosure")
if enc is None:
    raise SystemExit("ERROR: latest appcast item has no <enclosure>")
version = item.findtext("sparkle:shortVersionString", default="", namespaces=ns)
if not version:
    version = (item.findtext("title") or "").strip()
fields = [
    enc.attrib.get("url", ""),
    enc.attrib.get("{http://www.andymatuschak.org/xml-namespaces/sparkle}edSignature", ""),
    version,
    item.findtext("sparkle:version", default="", namespaces=ns),
]
print("\x1f".join(fields))
PY
)

IFS=$'\x1f' read -r ENCLOSURE_URL ED_SIG OFFERED_VERSION OFFERED_BUILD <<<"$PARSED"

echo "==> Live appcast (newest item)"
echo "    version:     $OFFERED_VERSION (build $OFFERED_BUILD)"
echo "    enclosure:   $ENCLOSURE_URL"
echo "    edSignature: ${ED_SIG:0:24}..."
echo

ISSUES=0
if [[ "$ENCLOSURE_URL" == *"steipete/CodexBar"* ]]; then
  echo "ERROR: feed points at upstream steipete/CodexBar releases."
  echo "       Sparkle will reject the signature because your app embeds the fork pubkey."
  ISSUES=$((ISSUES + 1))
fi
if [[ "$ENCLOSURE_URL" != *"$CODEXBAR_FORK_REPO"* ]]; then
  echo "ERROR: newest enclosure is not hosted on $CODEXBAR_FORK_REPO."
  ISSUES=$((ISSUES + 1))
fi
if grep -q "steipete/CodexBar" "$APPCAST_TMP"; then
  echo "ERROR: appcast still contains upstream steipete/CodexBar links."
  ISSUES=$((ISSUES + 1))
fi
if [[ "$CODEXBAR_FEED_URL" == "$UPSTREAM_FEED" ]]; then
  echo "ERROR: CODEXBAR_FEED_URL still points at upstream feed."
  ISSUES=$((ISSUES + 1))
fi

SIGN_TOOL=$(find "$ROOT/.build" -name sign_update -type f -path '*sparkle*' 2>/dev/null | head -1 || true)
if [[ -n "$SIGN_TOOL" && -n "${CODEXBAR_SPARKLE_PRIVATE_KEY_FILE:-}" && -f "$CODEXBAR_SPARKLE_PRIVATE_KEY_FILE" ]]; then
  ZIP_TMP=$(mktemp "${TMPDIR:-/tmp}/codexbar-zip.XXXXXX")
  trap 'rm -f "$APPCAST_TMP" "$ZIP_TMP"' EXIT
  echo "==> Verifying enclosure signature with your private key file"
  curl -fsSL "$ENCLOSURE_URL" -o "$ZIP_TMP"
  if "$SIGN_TOOL" --ed-key-file "$CODEXBAR_SPARKLE_PRIVATE_KEY_FILE" --verify "$ZIP_TMP" "$ED_SIG"; then
    echo "    signature:   OK (matches CODEXBAR_SPARKLE_PRIVATE_KEY_FILE)"
  else
    echo "    ERROR: enclosure signature does not match CODEXBAR_SPARKLE_PRIVATE_KEY_FILE"
    ISSUES=$((ISSUES + 1))
  fi
  echo
elif [[ -n "$SIGN_TOOL" ]]; then
  if "$SIGN_TOOL" -p /dev/null >/dev/null 2>&1; then
    echo "==> Sparkle private key: found in login Keychain"
  else
    echo "WARN: no Sparkle ed25519 key in login Keychain."
    echo "      Set CODEXBAR_SPARKLE_PRIVATE_KEY_FILE in .fork-release.env, or run:"
    echo "        .build/artifacts/sparkle/Sparkle/bin/generate_keys"
    ISSUES=$((ISSUES + 1))
  fi
  echo
fi

if [[ "$ISSUES" -gt 0 ]]; then
  echo "==> Result: BROKEN ($ISSUES issue(s))"
  echo
  echo "Fix:"
  echo "  1. Put your fork Sparkle private key in .fork-release.env:"
  echo "       CODEXBAR_SPARKLE_PRIVATE_KEY_FILE=/path/to/ed25519-private-key"
  echo "  2. Re-publish the fork appcast (after upstream main syncs overwrite it):"
  echo "       Scripts/fork-release.sh --appcast-only"
  echo "     or run a full release:"
  echo "       Scripts/fork-release.sh"
  echo "  3. After syncing main from upstream, always re-run step 2."
  exit 1
fi

echo "==> Result: feed looks consistent with fork settings"
