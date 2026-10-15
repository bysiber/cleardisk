#!/bin/bash
# Sign ClearDisk and every nested Sparkle helper from the inside out for Developer ID release.
set -euo pipefail

source "$(cd "$(dirname "$0")" && pwd)/_release_lib.sh"

IDENTITY="${IDENTITY:-${1:-}}"
[ -n "$IDENTITY" ] || die "Set IDENTITY or pass the Developer ID signing identity as the first argument."

APP="$ROOT_DIR/$APP_NAME.app"
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework"
[ -d "$APP" ] || die "App bundle not found: $APP"
[ -d "$SPARKLE" ] || die "Embedded Sparkle framework not found: $SPARKLE"

sign_nested() {
    codesign --force --timestamp --options runtime --sign "$IDENTITY" "$1"
}

# This is the order required by Sparkle for manual distribution signing. Downloader preserves its
# packaged entitlements; the other helpers intentionally receive no inherited app entitlements.
sign_nested "$SPARKLE/Versions/B/XPCServices/Installer.xpc"
codesign --force --timestamp --options runtime --preserve-metadata=entitlements \
    --sign "$IDENTITY" "$SPARKLE/Versions/B/XPCServices/Downloader.xpc"
sign_nested "$SPARKLE/Versions/B/Autoupdate"
sign_nested "$SPARKLE/Versions/B/Updater.app"
sign_nested "$SPARKLE"

codesign --force --timestamp --options runtime --sign "$IDENTITY" "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"

ok "Developer ID signed app and Sparkle helpers"
