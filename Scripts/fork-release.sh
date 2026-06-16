#!/usr/bin/env bash
# Self-contained fork release: build, sign, notarize, publish to your GitHub
# release, and generate a Sparkle appcast signed with your own key.
#
# Usage:
#   Scripts/fork-release.sh                 # full notarized release
#   Scripts/fork-release.sh --skip-notarize # signed-only local test build
#   Scripts/fork-release.sh --draft         # create the GitHub release as a draft
#
# Config comes from .fork-release.env (repo, identity, team, Sparkle key, feed URL).
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"

[[ -f "$ROOT/.fork-release.env" ]] || { echo "Missing .fork-release.env" >&2; exit 1; }
set -a
# shellcheck disable=SC1091
source "$ROOT/.fork-release.env"
set +a
# shellcheck disable=SC1091
source "$ROOT/version.env"
# shellcheck disable=SC1091
source "$ROOT/Scripts/release_artifacts.sh"

SKIP_NOTARIZE=0
DRAFT=0
for arg in "$@"; do
  case "$arg" in
    --skip-notarize) SKIP_NOTARIZE=1 ;;
    --draft) DRAFT=1 ;;
    *) echo "Unknown argument: $arg" >&2; exit 1 ;;
  esac
done

: "${CODEXBAR_FORK_REPO:?set CODEXBAR_FORK_REPO in .fork-release.env}"
: "${CODEXBAR_APP_IDENTITY:?set CODEXBAR_APP_IDENTITY in .fork-release.env}"
: "${CODEXBAR_SU_PUBLIC_ED_KEY:?set CODEXBAR_SU_PUBLIC_ED_KEY in .fork-release.env}"
: "${CODEXBAR_FEED_URL:?set CODEXBAR_FEED_URL in .fork-release.env}"
: "${APP_TEAM_ID:?set APP_TEAM_ID in .fork-release.env}"
export CODEXBAR_APP_IDENTITY CODEXBAR_SU_PUBLIC_ED_KEY CODEXBAR_FEED_URL APP_TEAM_ID
# package_app.sh reads APP_IDENTITY; mirror the fork identity into it.
export APP_IDENTITY="$CODEXBAR_APP_IDENTITY"

# The CommandLineTools `swift` is broken on this machine (dyld can't load
# BuildServerProtocol.framework). Fall back to a full Xcode toolchain for the build.
if [[ -z "${DEVELOPER_DIR:-}" ]] && [[ "$(xcode-select -p 2>/dev/null)" == *CommandLineTools* ]]; then
  for xc in /Applications/Xcode.app /Applications/Xcode-beta.app; do
    if [[ -d "$xc/Contents/Developer" ]]; then
      export DEVELOPER_DIR="$xc/Contents/Developer"
      break
    fi
  done
fi
echo "==> Toolchain: DEVELOPER_DIR=${DEVELOPER_DIR:-$(xcode-select -p)}"

VERSION="$MARKETING_VERSION"
TAG="v$VERSION"
ARCHES_VALUE="${ARCHES:-arm64 x86_64}"
ZIP_NAME=$(codexbar_app_zip_name "$VERSION" "$ARCHES_VALUE")
DSYM_ZIP=$(codexbar_dsym_zip_name "$VERSION" "$ARCHES_VALUE")

# Resolve the Sparkle sign_update tool (present after a build).
SIGN_TOOL=$(find "$ROOT/.build/artifacts/sparkle" -name sign_update -type f 2>/dev/null | head -1 || true)

echo "==> Fork release $TAG → $CODEXBAR_FORK_REPO (arches: $ARCHES_VALUE)"

# 1. Build + sign (+ notarize)
if [[ "$SKIP_NOTARIZE" == "1" ]]; then
  echo "==> Building + signing (Developer ID, NO notarization — local test only)"
  ARCHES="$ARCHES_VALUE" APP_IDENTITY="$CODEXBAR_APP_IDENTITY" ./Scripts/package_app.sh release
  /usr/bin/ditto --norsrc -c -k --keepParent CodexBar.app "$ZIP_NAME"
else
  : "${CODEXBAR_NOTARY_KEYCHAIN_PROFILE:?set CODEXBAR_NOTARY_KEYCHAIN_PROFILE in .fork-release.env (or run with --skip-notarize)}"
  export CODEXBAR_NOTARY_KEYCHAIN_PROFILE
  echo "==> Building + signing + notarizing (profile: $CODEXBAR_NOTARY_KEYCHAIN_PROFILE)"
  ./Scripts/sign-and-notarize.sh
fi

[[ -f "$ZIP_NAME" ]] || { echo "Expected build artifact missing: $ZIP_NAME" >&2; exit 1; }

# 2. Sparkle signature for the zip (uses the private key in your Keychain).
[[ -n "$SIGN_TOOL" ]] || SIGN_TOOL=$(find "$ROOT/.build" -name sign_update -type f -path '*sparkle*' 2>/dev/null | head -1 || true)
[[ -n "$SIGN_TOOL" ]] || { echo "Could not find Sparkle sign_update tool under .build" >&2; exit 1; }
echo "==> Signing update with your Sparkle key"
SIG_LINE=$("$SIGN_TOOL" "$ZIP_NAME")
ED_SIG=$(printf '%s' "$SIG_LINE" | sed -n 's/.*sparkle:edSignature="\([^"]*\)".*/\1/p')
LENGTH=$(printf '%s' "$SIG_LINE" | sed -n 's/.*length="\([^"]*\)".*/\1/p')
[[ -n "$ED_SIG" && -n "$LENGTH" ]] || { echo "Failed to parse sign_update output: $SIG_LINE" >&2; exit 1; }

# 3. Release notes from the top CHANGELOG section.
NOTES_MD=$(awk '/^## /{c++} c==1{print} c==2{exit}' CHANGELOG.md | sed '1d')
NOTES_HTML=$(printf '%s\n' "$NOTES_MD" | python3 -c '
import sys, html
out, inlist = [], False
for line in sys.stdin.read().splitlines():
    s = line.strip()
    if s.startswith("### "):
        if inlist: out.append("</ul>"); inlist = False
        out.append("<h3>" + html.escape(s[4:]) + "</h3>")
    elif s.startswith("- "):
        if not inlist: out.append("<ul>"); inlist = True
        out.append("<li>" + html.escape(s[2:]) + "</li>")
if inlist: out.append("</ul>")
print("\n".join(out))')

PUBDATE=$(date -u "+%a, %d %b %Y %H:%M:%S +0000")
DOWNLOAD_URL="https://github.com/$CODEXBAR_FORK_REPO/releases/download/$TAG/$ZIP_NAME"

# 4. Publish the GitHub release with assets.
echo "==> Publishing GitHub release $TAG"
ASSETS=("$ZIP_NAME")
[[ -f "$DSYM_ZIP" ]] && ASSETS+=("$DSYM_ZIP")
if gh release view "$TAG" --repo "$CODEXBAR_FORK_REPO" >/dev/null 2>&1; then
  echo "    release exists — uploading/clobbering assets"
  gh release upload "$TAG" "${ASSETS[@]}" --repo "$CODEXBAR_FORK_REPO" --clobber
else
  DRAFT_FLAG=()
  [[ "$DRAFT" == "1" ]] && DRAFT_FLAG=(--draft)
  printf '%s\n' "$NOTES_MD" | gh release create "$TAG" "${ASSETS[@]}" \
    --repo "$CODEXBAR_FORK_REPO" --title "CodexBar $VERSION" --notes-file - "${DRAFT_FLAG[@]}"
fi

# 5. Generate appcast.xml (single latest entry — all Sparkle needs to offer an update).
echo "==> Writing appcast.xml"
cat > appcast.xml <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" xmlns:dc="http://purl.org/dc/elements/1.1/">
  <channel>
    <title>CodexBar (${CODEXBAR_FORK_REPO} fork)</title>
    <link>${CODEXBAR_FEED_URL}</link>
    <description>CodexBar fork updates</description>
    <language>en</language>
    <item>
      <title>CodexBar ${VERSION}</title>
      <pubDate>${PUBDATE}</pubDate>
      <sparkle:version>${BUILD_NUMBER}</sparkle:version>
      <sparkle:shortVersionString>${VERSION}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
      <description><![CDATA[
${NOTES_HTML}
      ]]></description>
      <enclosure url="${DOWNLOAD_URL}" sparkle:edSignature="${ED_SIG}" length="${LENGTH}" type="application/octet-stream" />
    </item>
  </channel>
</rss>
XML

# 6. Publish appcast.xml to main via the GitHub API.
# Development happens on my-features and main stays synced with upstream, so we
# never check main out locally — we commit appcast.xml straight to the remote
# main branch. (main also carries upstream's appcast.xml, so upstream syncs will
# conflict on this file; resolve in favor of the fork.)
echo "==> Publishing appcast.xml to main on $CODEXBAR_FORK_REPO"
APPCAST_B64=$(base64 < appcast.xml | tr -d '\n')
APPCAST_SHA=$(gh api "repos/$CODEXBAR_FORK_REPO/contents/appcast.xml?ref=main" --jq .sha 2>/dev/null || true)
SHA_ARGS=()
[[ -n "$APPCAST_SHA" ]] && SHA_ARGS=(-f "sha=$APPCAST_SHA")
gh api --method PUT "repos/$CODEXBAR_FORK_REPO/contents/appcast.xml" \
  -f "message=release: CodexBar $VERSION fork appcast" \
  -f "branch=main" \
  "${SHA_ARGS[@]}" \
  -f "content=$APPCAST_B64" \
  --jq '"    committed " + .commit.sha[0:7] + " to main"'

cat <<DONE

==> Done.
    Release:  https://github.com/${CODEXBAR_FORK_REPO}/releases/tag/${TAG}
    Asset:    ${DOWNLOAD_URL}
    Feed:     ${CODEXBAR_FEED_URL}

    appcast.xml is live on main — auto-update is active. Verify with:
      curl -s ${CODEXBAR_FEED_URL} | grep enclosure
DONE
