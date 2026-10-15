#!/bin/bash
#
# Point the Homebrew cask at the published GitHub release.
# Run this LAST — the cask URL is the release asset, so the DMG must already be uploaded.
#
# Usage:
#   ./scripts/brew_update.sh                 # hash the published DMG and update the cask
#   ./scripts/brew_update.sh --sha256 <hash> # trust this hash instead of downloading
#   ./scripts/brew_update.sh --dry-run       # print the cask, change nothing
#
# The version and the checksum used to be hand-typed positional arguments. They are now derived:
# the version from scripts/build_app.sh, the sha256 from the DMG that is actually on the release.
# Hand-typed values are what let the cask drift from reality (see the zap note below).
#
# Requires: gh, authenticated with push access to the tap repo.

source "$(cd "$(dirname "$0")" && pwd)/_release_lib.sh"

SHA=""
DRY_RUN="no"
while [ $# -gt 0 ]; do
    case "$1" in
        --sha256)  SHA="${2:-}"; shift 2 ;;
        --dry-run) DRY_RUN="yes"; shift ;;
        -h|--help) sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *)         die "Unknown option: $1 (try --help)" ;;
    esac
done

require_cmd gh
require_cmd shasum
gh auth status >/dev/null 2>&1 || die "gh is not authenticated. Run: gh auth login"

VERSION="$(project_version)"
TAG="v$VERSION"
DMG_NAME="$APP_NAME-$TAG.dmg"

# The cask sends every user to the release URL. If the asset is not actually there, the cask
# would publish a guaranteed-404 install. Check before touching the tap.
info "Checking release $TAG for $DMG_NAME"
gh release view "$TAG" --repo "$REPO" --json assets --jq '.assets[].name' 2>/dev/null \
    | grep -qx "$DMG_NAME" \
    || die "$DMG_NAME is not attached to release $TAG (or the release is still a draft).
     Run ./scripts/do_gh.sh first, and publish the release if you created it as a draft."

if [ -z "$SHA" ]; then
    # Hash what users will really download, not whatever happens to sit in dist/. If a rebuild
    # changed the bytes after the upload, the local file and the release would silently differ
    # and every `brew install` would abort on a checksum mismatch.
    TMP="$(mktemp -d)"
    trap 'rm -rf "$TMP"' EXIT
    info "Downloading the published DMG to hash it"
    gh release download "$TAG" --repo "$REPO" --pattern "$DMG_NAME" --dir "$TMP" >/dev/null
    SHA="$(shasum -a 256 "$TMP/$DMG_NAME" | awk '{print $1}')"

    LOCAL_SHA_FILE="$(dmg_path "$VERSION").sha256"
    if [ -f "$LOCAL_SHA_FILE" ] && [ "$(cat "$LOCAL_SHA_FILE")" != "$SHA" ]; then
        warn "Your local dist/ DMG differs from the one on the release. Using the published one."
    fi
fi

ok "sha256: $SHA"

# Note: #{version} below is Ruby interpolation evaluated by Homebrew, not by bash.
#
# `depends_on macos: :sonoma` is a MINIMUM — Homebrew resolves it to "macOS >= 14". Keep the bare
# symbol: the older `">= :sonoma"` string comparison is deprecated and made Homebrew print a
# warning on every install (reported by @theeseuus in #20, fixed by @bromaniac in #21).
#
# The zap paths must match the app's real bundle id, com.cleardisk.app. They said
# com.bysiber.ClearDisk for months, so `brew uninstall --zap` silently removed nothing.
CASK=$(cat << CASKEOF
cask "cleardisk" do
  version "$VERSION"
  sha256 "$SHA"

  url "https://github.com/$REPO/releases/download/v#{version}/$APP_NAME-v#{version}.dmg"
  name "$APP_NAME"
  desc "Free, open-source macOS app to find and clean developer caches"
  homepage "https://github.com/$REPO"

  auto_updates true
  depends_on macos: :sonoma

  app "$APP_NAME.app"

  postflight do
    system_command "/usr/bin/xattr",
                   args: ["-cr", "#{appdir}/$APP_NAME.app"],
                   sudo: false
  end

  zap trash: [
    "~/Library/Preferences/$BUNDLE_ID.plist",
    "~/Library/Caches/$BUNDLE_ID",
    "~/Library/Saved Application State/$BUNDLE_ID.savedState",
  ]
end
CASKEOF
)

if [ "$DRY_RUN" = "yes" ]; then
    echo
    echo "$CASK"
    echo
    ok "dry run — $TAP_REPO was not touched"
    exit 0
fi

info "Updating $TAP_REPO/$CASK_PATH"

# Updating a file through the contents API needs the blob sha of the version being replaced.
# It is absent the first time the cask is created, which is fine.
GIT_SHA="$(gh api "repos/$TAP_REPO/contents/$CASK_PATH" --jq '.sha' 2>/dev/null || true)"

PAYLOAD="$(mktemp)"
trap 'rm -f "$PAYLOAD"' EXIT
CONTENT_B64="$(printf '%s\n' "$CASK" | base64)"

if [ -n "$GIT_SHA" ]; then
    printf '{"message":"Update cask to %s","content":"%s","sha":"%s"}' \
        "$TAG" "$CONTENT_B64" "$GIT_SHA" > "$PAYLOAD"
else
    warn "Cask does not exist yet in the tap — creating it."
    printf '{"message":"Add cask %s","content":"%s"}' \
        "$TAG" "$CONTENT_B64" > "$PAYLOAD"
fi

COMMIT_URL="$(gh api "repos/$TAP_REPO/contents/$CASK_PATH" -X PUT --input "$PAYLOAD" --jq '.commit.html_url')"

ok "cask updated: $COMMIT_URL"
echo
echo "Users can now update with:"
echo "  brew update && brew upgrade --cask cleardisk"
echo
echo "Verify with a clean install:"
echo "  brew uninstall --cask cleardisk 2>/dev/null; brew install --cask cleardisk"
