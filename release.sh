#!/bin/bash
set -euo pipefail

# ClearDisk Release Script
# Usage: ./release.sh <version>     -- new release (e.g. ./release.sh 1.6.3)
# Usage: ./release.sh <version> -u  -- update existing release (rebuild + replace DMG)

VERSION="${1:-}"
UPDATE_ONLY="${2:-}"

if [ -z "$VERSION" ]; then
    echo "Usage: ./release.sh <version> [-u]"
    echo "  ./release.sh 1.6.3      Create new release v1.6.3"
    echo "  ./release.sh 1.6.2 -u   Update existing v1.6.2 (rebuild + replace DMG)"
    exit 1
fi

TAG="v${VERSION}"
DMG_NAME="ClearDisk-${TAG}.dmg"

echo "==> Building release binary..."
swift build -c release 2>&1 | tail -3

echo "==> Creating .app bundle..."
./build_app.sh 2>&1 | tail -3

echo "==> Creating DMG with Applications shortcut..."
rm -rf /tmp/dmg_staging
mkdir -p /tmp/dmg_staging
cp -R ClearDisk.app /tmp/dmg_staging/
ln -s /Applications /tmp/dmg_staging/Applications
rm -f "$DMG_NAME"
hdiutil create -volname ClearDisk -srcfolder /tmp/dmg_staging -ov -format UDZO "$DMG_NAME" 2>&1 | tail -1
rm -rf /tmp/dmg_staging

DMG_SHA=$(shasum -a 256 "$DMG_NAME" | awk '{print $1}')
echo "==> DMG: $DMG_NAME"
echo "==> SHA256: $DMG_SHA"

if [ "$UPDATE_ONLY" = "-u" ]; then
    echo "==> Updating existing release ${TAG}..."
    
    # Update tag to latest main
    LATEST=$(git rev-parse HEAD)
    git tag -f "$TAG" "$LATEST"
    git push origin "$TAG" --force
    
    # Replace DMG
    gh release delete-asset "$TAG" "$DMG_NAME" --repo bysiber/cleardisk -y 2>/dev/null || true
    gh release upload "$TAG" "$DMG_NAME" --repo bysiber/cleardisk
else
    echo "==> Creating new release ${TAG}..."
    
    # Create tag
    git tag "$TAG"
    git push origin "$TAG"
    
    # Create release (will prompt for notes or use --notes-file)
    if [ -f /tmp/release_notes.txt ]; then
        gh release create "$TAG" "$DMG_NAME" --title "ClearDisk ${TAG}" --notes-file /tmp/release_notes.txt --latest --repo bysiber/cleardisk
    else
        gh release create "$TAG" "$DMG_NAME" --title "ClearDisk ${TAG}" --generate-notes --latest --repo bysiber/cleardisk
    fi
fi

echo "==> Updating Homebrew cask..."
GIT_SHA=$(gh api repos/bysiber/homebrew-cleardisk/contents/Casks/cleardisk.rb --jq '.sha')

cat > /tmp/cleardisk_cask.rb << CASKEOF
cask "cleardisk" do
  version "${VERSION}"
  sha256 "${DMG_SHA}"

  url "https://github.com/bysiber/cleardisk/releases/download/v#{version}/ClearDisk-v#{version}.dmg"
  name "ClearDisk"
  desc "Free, open-source macOS app to find and clean developer caches"
  homepage "https://github.com/bysiber/cleardisk"

  depends_on macos: ">= :sonoma"

  app "ClearDisk.app"

  postflight do
    system_command "/usr/bin/xattr",
                   args: ["-cr", "#{appdir}/ClearDisk.app"],
                   sudo: false
  end

  zap trash: [
    "~/Library/Preferences/com.bysiber.ClearDisk.plist",
    "~/Library/Caches/com.bysiber.ClearDisk",
  ]
end
CASKEOF

CONTENT=$(base64 < /tmp/cleardisk_cask.rb)
printf '{"message":"Update cask to %s","content":"%s","sha":"%s"}' "$TAG" "$CONTENT" "$GIT_SHA" > /tmp/cask_payload.json
COMMIT_URL=$(gh api repos/bysiber/homebrew-cleardisk/contents/Casks/cleardisk.rb -X PUT --input /tmp/cask_payload.json --jq '.commit.html_url')

echo ""
echo "=== Release Complete ==="
echo "Release: https://github.com/bysiber/cleardisk/releases/tag/${TAG}"
echo "Homebrew: ${COMMIT_URL}"
echo "DMG SHA: ${DMG_SHA}"
echo ""
echo "Users can now update via:"
echo "  brew update && brew upgrade --cask cleardisk"
