#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"

[[ -f .fork-release.env ]] || { echo "Missing .fork-release.env" >&2; exit 1; }
# shellcheck disable=SC1091
source .fork-release.env
# shellcheck disable=SC1091
source version.env

: "${CODEXBAR_FORK_REPO:?set CODEXBAR_FORK_REPO in .fork-release.env}"
: "${CODEXBAR_APP_IDENTITY:?set CODEXBAR_APP_IDENTITY in .fork-release.env}"
: "${CODEXBAR_FEED_URL:?set CODEXBAR_FEED_URL in .fork-release.env}"
: "${CODEXBAR_SU_PUBLIC_ED_KEY:?set CODEXBAR_SU_PUBLIC_ED_KEY in .fork-release.env}"
: "${CODEXBAR_NOTARY_KEYCHAIN_PROFILE:?set CODEXBAR_NOTARY_KEYCHAIN_PROFILE in .fork-release.env}"
: "${APP_TEAM_ID:?set APP_TEAM_ID in .fork-release.env}"

export APP_IDENTITY="$CODEXBAR_APP_IDENTITY"
export ARCHES=arm64
export CODEXBAR_APP_IDENTITY
export CODEXBAR_DMG_ONLY=1
export CODEXBAR_EMBED_PROVISIONING_PROFILE=0
export CODEXBAR_FEED_URL
export CODEXBAR_SKIP_LAUNCH_SMOKE=1
export CODEXBAR_NOTARY_KEYCHAIN_PROFILE
export CODEXBAR_SKIP_WIDGET=1
export CODEXBAR_SU_PUBLIC_ED_KEY
export APP_TEAM_ID

# shellcheck disable=SC1091
source Scripts/select_xcode_toolchain.sh
codexbar_select_xcode_toolchain

TAG="v$MARKETING_VERSION"
DMG_NAME="CodexBar-macos-arm64-$MARKETING_VERSION.dmg"

echo "==> ARM64 DMG release $TAG → $CODEXBAR_FORK_REPO"
./Scripts/sign-and-notarize.sh
[[ -f "$DMG_NAME" ]] || { echo "Missing release artifact: $DMG_NAME" >&2; exit 1; }

APP_PLIST="$ROOT/CodexBar.app/Contents/Info.plist"
[[ -f "$APP_PLIST" ]] || { echo "Missing packaged app Info.plist: $APP_PLIST" >&2; exit 1; }
PACKAGED_FEED_URL=$(/usr/libexec/PlistBuddy -c 'Print :SUFeedURL' "$APP_PLIST")
PACKAGED_PUBLIC_KEY=$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$APP_PLIST")
[[ "$PACKAGED_FEED_URL" == "$CODEXBAR_FEED_URL" ]] || {
  echo "Packaged app feed URL does not match CODEXBAR_FEED_URL" >&2
  exit 1
}
[[ "$PACKAGED_PUBLIC_KEY" == "$CODEXBAR_SU_PUBLIC_ED_KEY" ]] || {
  echo "Packaged app Sparkle public key does not match CODEXBAR_SU_PUBLIC_ED_KEY" >&2
  exit 1
}

if ! gh release view "$TAG" --repo "$CODEXBAR_FORK_REPO" >/dev/null 2>&1; then
  NOTES=$(awk '/^## /{section++} section==1{print} section==2{exit}' CHANGELOG.md | sed '1d')
  gh release create "$TAG" \
    --repo "$CODEXBAR_FORK_REPO" \
    --verify-tag \
    --title "CodexBar $MARKETING_VERSION" \
    --notes "$NOTES"
fi

gh release upload "$TAG" "$DMG_NAME" --repo "$CODEXBAR_FORK_REPO" --clobber

SIGN_TOOL=$(find .build -path '*sparkle*' -type f -name sign_update | head -1)
[[ -n "$SIGN_TOOL" ]] || { echo "Missing Sparkle sign_update tool" >&2; exit 1; }
if [[ -n "${CODEXBAR_SPARKLE_PRIVATE_KEY_FILE:-}" ]]; then
  SIG_LINE=$("$SIGN_TOOL" --ed-key-file "$CODEXBAR_SPARKLE_PRIVATE_KEY_FILE" "$DMG_NAME")
else
  SIG_LINE=$("$SIGN_TOOL" "$DMG_NAME")
fi
ED_SIGNATURE=$(printf '%s' "$SIG_LINE" | sed -n 's/.*sparkle:edSignature="\([^"]*\)".*/\1/p')
LENGTH=$(printf '%s' "$SIG_LINE" | sed -n 's/.*length="\([^"]*\)".*/\1/p')
[[ -n "$ED_SIGNATURE" && -n "$LENGTH" ]] || { echo "Failed to sign DMG for Sparkle" >&2; exit 1; }

# Sparkle release notes: the Highlights bullets of the newest CHANGELOG section,
# converted to HTML.
RELEASE_HTML=$(awk '
  /^## /   { section++; next }
  section != 1 { next }
  /^### /  { inhl = ($0 ~ /^### Highlights/); next }
  inhl && /^- / { sub(/^- /, ""); print }
' CHANGELOG.md | python3 -c '
import html, re, sys
items = []
for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    line = html.escape(line)
    line = re.sub(r"\*\*(.+?)\*\*", r"<strong>\1</strong>", line)
    line = re.sub(r"`(.+?)`", r"<code>\1</code>", line)
    items.append(f"<li>{line}</li>")
print("<h3>Highlights</h3><ul>" + "".join(items) + "</ul>" if items else "")
')
[[ -n "$RELEASE_HTML" ]] || { echo "Failed to build Sparkle release notes from CHANGELOG.md" >&2; exit 1; }

PUBDATE=$(date -u "+%a, %d %b %Y %H:%M:%S +0000")
DOWNLOAD_URL="https://github.com/$CODEXBAR_FORK_REPO/releases/download/$TAG/$DMG_NAME"
APPCAST_TMP=$(mktemp "${TMPDIR:-/tmp}/codexbar-appcast.XXXXXX")
cat >"$APPCAST_TMP" <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>CodexBar (${CODEXBAR_FORK_REPO} fork)</title>
    <link>${CODEXBAR_FEED_URL}</link>
    <description>CodexBar fork updates</description>
    <language>en</language>
    <item>
      <title>CodexBar ${MARKETING_VERSION}</title>
      <pubDate>${PUBDATE}</pubDate>
      <sparkle:version>${BUILD_NUMBER}</sparkle:version>
      <sparkle:shortVersionString>${MARKETING_VERSION}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
      <description><![CDATA[${RELEASE_HTML}]]></description>
      <enclosure url="${DOWNLOAD_URL}" sparkle:edSignature="${ED_SIGNATURE}" length="${LENGTH}" type="application/octet-stream" />
    </item>
  </channel>
</rss>
XML

APPCAST_B64=$(base64 <"$APPCAST_TMP" | tr -d '\n')
APPCAST_SHA=$(gh api "repos/$CODEXBAR_FORK_REPO/contents/appcast.xml?ref=main" --jq .sha)
gh api --method PUT "repos/$CODEXBAR_FORK_REPO/contents/appcast.xml" \
  -f "message=release: CodexBar $MARKETING_VERSION fork appcast" \
  -f "branch=main" \
  -f "sha=$APPCAST_SHA" \
  -f "content=$APPCAST_B64" \
  --jq '.commit.sha'
rm -f "$APPCAST_TMP"

echo "==> Published: https://github.com/$CODEXBAR_FORK_REPO/releases/tag/$TAG"
echo "==> Appcast: $CODEXBAR_FEED_URL"
