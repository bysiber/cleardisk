#!/bin/bash
# Build ClearDisk.app bundle (universal: arm64 + x86_64)
set -euo pipefail

source "$(cd "$(dirname "$0")" && pwd)/_release_lib.sh"

VERSION="$(project_version)"
BUILD_NUMBER="$(git -C "$ROOT_DIR" rev-list --count HEAD)"

# Architectures for the release binary. One DMG runs on Apple Silicon and Intel.
# Override for a faster host-only build: ARCHES=arm64 ./scripts/build_app.sh
ARCHES=(${ARCHES:-arm64 x86_64})

APP_BUNDLE="$ROOT_DIR/$APP_NAME.app"
MACOS_DIR="$APP_BUNDLE/Contents/MacOS"
BINARY_OUT="$MACOS_DIR/$APP_NAME"
FRAMEWORKS_DIR="$APP_BUNDLE/Contents/Frameworks"
SPARKLE_FRAMEWORK="$ROOT_DIR/.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
SPARKLE_PUBLIC_KEY="l98DVS+1hODBo7XylBUsfUr+gCN/+40tuPcXjVsqlGc="

triple_for_arch() {
    printf '%s-apple-macosx' "$1"
}

binary_path_for_arch() {
    local arch="$1"
    printf '%s/.build/%s/release/%s' "$ROOT_DIR" "$(triple_for_arch "$arch")" "$APP_NAME"
}

assert_universal() {
    local info
    info="$(lipo -info "$BINARY_OUT")"
    echo "$info"
    echo "$info" | grep -q 'arm64' || {
        echo "error: fat binary missing arm64 slice: $info" >&2
        exit 1
    }
    echo "$info" | grep -q 'x86_64' || {
        echo "error: fat binary missing x86_64 slice: $info" >&2
        exit 1
    }
}

require_cmd swift
require_cmd lipo
require_cmd codesign
require_cmd file
require_cmd ditto
require_cmd install_name_tool

echo "Building $APP_NAME (${ARCHES[*]})..."
cd "$ROOT_DIR"

BUILT_BINS=()
for arch in "${ARCHES[@]}"; do
    triple="$(triple_for_arch "$arch")"
    echo "  -> swift build -c release --triple $triple"
    swift build -c release --triple "$triple" 2>&1
    bin="$(binary_path_for_arch "$arch")"
    if [ ! -f "$bin" ]; then
        echo "error: expected binary missing after $arch build: $bin" >&2
        exit 1
    fi
    BUILT_BINS+=("$bin")
done

echo "Creating app bundle..."
rm -rf "$APP_BUNDLE"
mkdir -p "$MACOS_DIR"
mkdir -p "$APP_BUNDLE/Contents/Resources"
mkdir -p "$FRAMEWORKS_DIR"

if [ "${#BUILT_BINS[@]}" -eq 1 ]; then
    cp "${BUILT_BINS[0]}" "$BINARY_OUT"
else
    lipo -create "${BUILT_BINS[@]}" -output "$BINARY_OUT"
    assert_universal
fi

file "$BINARY_OUT"

# SwiftPM links Sparkle through @rpath but its command-line build output assumes the framework is
# beside the executable. A real app bundle keeps frameworks in Contents/Frameworks, so add that
# standard runtime search path and preserve Sparkle's symlinks while embedding it.
[ -d "$SPARKLE_FRAMEWORK" ] || {
    echo "error: Sparkle.framework missing after Swift build: $SPARKLE_FRAMEWORK" >&2
    exit 1
}
install_name_tool -add_rpath "@executable_path/../Frameworks" "$BINARY_OUT"
ditto "$SPARKLE_FRAMEWORK" "$FRAMEWORKS_DIR/Sparkle.framework"

# Copy app icon
if [ -f "Resources/AppIcon.icns" ]; then
    cp "Resources/AppIcon.icns" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
    echo "App icon copied."
fi

# Keep third-party notices inside the app bundle; no user-facing attribution is required.
THIRD_PARTY_DIR="$APP_BUNDLE/Contents/Resources/ThirdPartyLicenses"
mkdir -p "$THIRD_PARTY_DIR"
cp "Vendor/DiskScanBackend/LICENSE.txt" "$THIRD_PARTY_DIR/DiskScannerMIT.txt"
cp ".build/artifacts/sparkle/Sparkle/LICENSE" "$THIRD_PARTY_DIR/SparkleLicense.txt"

# Create Info.plist (unquoted heredoc so $VERSION / $BUILD_NUMBER expand)
cat > "$APP_BUNDLE/Contents/Info.plist" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>ClearDisk</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIdentifier</key>
    <string>com.cleardisk.app</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>ClearDisk</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>${VERSION}</string>
    <key>CFBundleVersion</key>
    <string>${BUILD_NUMBER}</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>SUFeedURL</key>
    <string>https://github.com/bysiber/cleardisk/releases/latest/download/appcast.xml</string>
    <key>SUPublicEDKey</key>
    <string>${SPARKLE_PUBLIC_KEY}</string>
    <key>SUEnableAutomaticChecks</key>
    <true/>
    <key>SUScheduledCheckInterval</key>
    <integer>86400</integer>
    <key>SUAutomaticallyUpdate</key>
    <false/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSHumanReadableCopyright</key>
    <string>Copyright 2026. All rights reserved.</string>
</dict>
</plist>
EOF

# Ad-hoc code sign the entire bundle (better Gatekeeper handling than linker-signed)
codesign --force --deep -s - "$APP_BUNDLE"
echo "Code signed (ad-hoc)."

echo "Done! App bundle created at: $APP_BUNDLE"
echo "To run: open $APP_BUNDLE"
ls -la "$BINARY_OUT"
