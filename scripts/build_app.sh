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

if [ "${#BUILT_BINS[@]}" -eq 1 ]; then
    cp "${BUILT_BINS[0]}" "$BINARY_OUT"
else
    lipo -create "${BUILT_BINS[@]}" -output "$BINARY_OUT"
    assert_universal
fi

file "$BINARY_OUT"

# Copy app icon
if [ -f "Resources/AppIcon.icns" ]; then
    cp "Resources/AppIcon.icns" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
    echo "App icon copied."
fi

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
