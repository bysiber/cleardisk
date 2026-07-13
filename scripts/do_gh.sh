#!/bin/bash
#
# Tag the release and publish it on GitHub with the DMG attached.
# Release notes are taken from the matching section of CHANGELOG.md.
#
# Usage:
#   ./scripts/do_gh.sh                    # publish
#   ./scripts/do_gh.sh --draft            # create the release as a draft first
#   ./scripts/do_gh.sh --notes-file X.md  # override the notes
#   ./scripts/do_gh.sh --allow-dirty      # publish with uncommitted changes (not advised)
#
# Requires: gh (authenticated), and dist/ClearDisk-v<version>.dmg from do_dmg.sh.

source "$(cd "$(dirname "$0")" && pwd)/_release_lib.sh"

DRAFT=""
NOTES_FILE=""
ALLOW_DIRTY="no"
while [ $# -gt 0 ]; do
    case "$1" in
        --draft)       DRAFT="--draft"; shift ;;
        --notes-file)  NOTES_FILE="${2:-}"; shift 2 ;;
        --allow-dirty) ALLOW_DIRTY="yes"; shift ;;
        -h|--help)     sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *)             die "Unknown option: $1 (try --help)" ;;
    esac
done

require_cmd gh
require_cmd git
gh auth status >/dev/null 2>&1 || die "gh is not authenticated. Run: gh auth login"

cd "$ROOT_DIR"

VERSION="$(project_version)"
TAG="v$VERSION"
DMG="$(dmg_path "$VERSION")"

[ -f "$DMG" ] || die "$(basename "$DMG") not found. Run ./scripts/do_dmg.sh first."

# A release is a permanent, public artifact. Refuse to cut one from a tree that does not match
# what is on the branch — the tag would point at a commit that does not contain the shipped code.
BRANCH="$(git rev-parse --abbrev-ref HEAD)"
[ "$BRANCH" = "main" ] || warn "You are on '$BRANCH', not main."
if [ -n "$(git status --porcelain)" ]; then
    [ "$ALLOW_DIRTY" = "yes" ] \
        || die "Working tree has uncommitted changes. Commit them, or pass --allow-dirty."
    warn "Publishing with a dirty working tree."
fi

if [ -n "$NOTES_FILE" ]; then
    [ -f "$NOTES_FILE" ] || die "Notes file not found: $NOTES_FILE"
    NOTES="$(cat "$NOTES_FILE")"
else
    NOTES="$(changelog_section "$VERSION")"
    [ -n "$NOTES" ] || die "No '## [$VERSION]' section in CHANGELOG.md. Add one, or pass --notes-file."
fi

# Two things bite every release and both must be spelled out here.
#   1. Recent Homebrew refuses casks from untrusted third-party taps, so `brew trust` is required.
#   2. Downloaded DMGs are ad-hoc signed and not notarized, so Gatekeeper blocks them. The old
#      right-click → Open bypass no longer exists: Apple removed it in macOS 15, and the only
#      routes left are System Settings → Open Anyway, or clearing the quarantine attribute.
NOTES="$NOTES

---
### Install

\`\`\`sh
brew tap $(dirname "$TAP_REPO")/cleardisk
brew trust $(dirname "$TAP_REPO")/cleardisk
brew install --cask cleardisk
\`\`\`

Or download the DMG below and drag ClearDisk to Applications. The app is ad-hoc signed and not
notarized, so macOS blocks it on first launch. To open it:

- **System Settings → Privacy & Security**, scroll down, click **Open Anyway**, or
- \`xattr -cr /Applications/ClearDisk.app\` in Terminal.

(Homebrew does this for you.)"

info "Tagging $TAG"
if git rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then
    ok "tag $TAG already exists locally"
else
    git tag -a "$TAG" -m "$APP_NAME $TAG"
fi
git push origin "$TAG" 2>/dev/null || ok "tag $TAG already on origin"

if gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1; then
    info "Release $TAG exists — replacing its DMG"
    gh release upload "$TAG" "$DMG" --repo "$REPO" --clobber
else
    info "Creating release $TAG"
    gh release create "$TAG" "$DMG" \
        --repo "$REPO" \
        --title "$APP_NAME $TAG" \
        --notes "$NOTES" \
        $DRAFT
fi

ok "https://github.com/$REPO/releases/tag/$TAG"
echo
if [ -n "$DRAFT" ]; then
    echo "Draft created. Publish it on GitHub, THEN run ./scripts/brew_update.sh"
else
    echo "Next:  ./scripts/brew_update.sh   # point the cask at this release"
fi
