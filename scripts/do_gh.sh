#!/bin/bash
# Trigger the signed GitHub release pipeline by creating and pushing the changelog version tag.
# GitHub Actions owns all public artifacts: Developer ID signing, notarization, Sparkle appcast,
# GitHub Release publication, and the Homebrew cask update.
#
# Usage:
#   ./scripts/do_gh.sh
#   ./scripts/do_gh.sh --dry-run

set -euo pipefail
source "$(cd "$(dirname "$0")" && pwd)/_release_lib.sh"

DRY_RUN="no"
case "${1:-}" in
    "") ;;
    --dry-run) DRY_RUN="yes" ;;
    -h|--help) sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "Unknown option: $1 (try --help)" ;;
esac

require_cmd git
cd "$ROOT_DIR"

VERSION="$(project_version)"
TAG="v$VERSION"
BRANCH="$(git rev-parse --abbrev-ref HEAD)"

[ "$BRANCH" = "main" ] || die "Release tags must be created from main (currently $BRANCH)."
[ -z "$(git status --porcelain)" ] || die "Working tree is dirty. Commit and review changes first."

NOTES="$(changelog_section "$VERSION")"
[ -n "$NOTES" ] || die "CHANGELOG.md has no release notes for $VERSION."

git fetch origin main --quiet
[ "$(git rev-parse HEAD)" = "$(git rev-parse origin/main)" ] \
    || die "Local main must exactly match origin/main before creating a release tag. Push or pull first."

if git ls-remote --exit-code --tags origin "refs/tags/$TAG" >/dev/null 2>&1; then
    die "$TAG already exists on origin. Bump the first version in CHANGELOG.md."
fi

if [ "$DRY_RUN" = "yes" ]; then
    info "Would create and push $TAG from $(git rev-parse --short HEAD)"
    exit 0
fi

if git rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then
    [ "$(git rev-parse "refs/tags/$TAG^{}")" = "$(git rev-parse HEAD)" ] \
        || die "Local $TAG points to a different commit. Remove or correct it before releasing."
else
    git tag -a "$TAG" -m "$APP_NAME $TAG"
fi

git push origin "$TAG"
ok "Release pipeline started for $TAG"
echo "   https://github.com/$REPO/actions/workflows/release.yml"
