#!/bin/bash
#
# Build the release .app and package it as dist/ClearDisk-v<version>.dmg
#
# Usage:
#   ./scripts/do_dmg.sh                  # version comes from CHANGELOG.md
#   ./scripts/do_dmg.sh --version 1.8.0  # only to double-check; must match CHANGELOG.md
#
# Writes the DMG plus a <dmg>.sha256 sidecar that brew_update.sh picks up automatically.

source "$(cd "$(dirname "$0")" && pwd)/_release_lib.sh"

VERSION=""
while [ $# -gt 0 ]; do
    case "$1" in
        --version) VERSION="${2:-}"; shift 2 ;;
        -h|--help) sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *)         die "Unknown option: $1 (try --help)" ;;
    esac
done

require_cmd hdiutil
require_cmd shasum
require_cmd plutil

DECLARED="$(project_version)"
if [ -z "$VERSION" ]; then
    VERSION="$DECLARED"
elif [ "$VERSION" != "$DECLARED" ]; then
    die "--version $VERSION does not match \"$DECLARED\" in CHANGELOG.md.
     Bump it there — that file is the single source of truth."
fi

info "Building $APP_NAME $VERSION (release)"
# Keep build_app stdout visible — it asserts universal slices and prints lipo/file output.
"$SCRIPTS_DIR/build_app.sh"

APP="$ROOT_DIR/$APP_NAME.app"
[ -d "$APP" ] || die "$APP was not produced by build_app.sh"

BIN="$APP/Contents/MacOS/$APP_NAME"
[ -f "$BIN" ] || die "Missing executable: $BIN"
LIPO_INFO="$(lipo -info "$BIN" 2>/dev/null || true)"
echo "$LIPO_INFO" | grep -q 'arm64'  || die "Release binary is not universal (missing arm64): $LIPO_INFO"
echo "$LIPO_INFO" | grep -q 'x86_64' || die "Release binary is not universal (missing x86_64): $LIPO_INFO"
ok "universal binary: $LIPO_INFO"

# The DMG filename is baked into the Homebrew cask URL, so a stale bundle would ship under the
# wrong name and every `brew install` would fetch the wrong build. Catch that here, not later.
BUILT="$(plutil -extract CFBundleShortVersionString raw "$APP/Contents/Info.plist")"
[ "$BUILT" = "$VERSION" ] \
    || die "Bundle reports $BUILT but we are releasing $VERSION. build_app.sh did not pick up the bump."

DMG="$(dmg_path "$VERSION")"
mkdir -p "$DIST_DIR"

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

cp -R "$APP" "$STAGE/$APP_NAME.app"
# Users drag the app onto this symlink to install it.
ln -s /Applications "$STAGE/Applications"
# Don't bake quarantine / provenance attributes into the image.
xattr -cr "$STAGE/$APP_NAME.app"

info "Creating disk image"
rm -f "$DMG"
hdiutil create \
    -volname "$APP_NAME" \
    -srcfolder "$STAGE" \
    -ov -format UDZO \
    "$DMG" >/dev/null

SHA="$(shasum -a 256 "$DMG" | awk '{print $1}')"
printf '%s' "$SHA" > "$DMG.sha256"

ok "$(basename "$DMG")  ($(du -h "$DMG" | cut -f1))"
echo "   sha256: $SHA"
echo
echo "Next:  ./scripts/do_gh.sh        # publish the release with this DMG"
