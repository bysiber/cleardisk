#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CD_ROOT="$(dirname "$SCRIPT_DIR")"
cd "$CD_ROOT"

# Homebrew Cask Update Script
# Usage: ./brew_update.sh <version> <dmg_sha256>
# Example: ./brew_update.sh 1.6.4 abc123...

VERSION="${1:-}"
DMG_SHA="${2:-}"

if [ -z "$VERSION" ] || [ -z "$DMG_SHA" ]; then
    echo "Usage: ./brew_update.sh <version> <dmg_sha256>"
    echo "  ./brew_update.sh 1.6.4 abc123def456..."
    exit 1
fi

TAG="v${VERSION}"

echo "==> Updating Homebrew cask to ${TAG}..."

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
echo "=== Homebrew Updated ==="
echo "Commit: ${COMMIT_URL}"
echo "DMG SHA: ${DMG_SHA}"
echo ""
echo "Users can now update via:"
echo "  brew update && brew upgrade --cask cleardisk"
