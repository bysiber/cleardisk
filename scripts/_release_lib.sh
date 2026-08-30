#!/bin/bash
# Shared helpers for the release scripts. Source this, don't run it.
#
#   do_dmg.sh       build an ad-hoc local DMG for inspection
#   do_gh.sh        create and push the release tag
#   brew_update.sh  point the Homebrew cask at a published DMG (normally run by CI)
#
# Release tags trigger GitHub Actions, which performs Developer ID signing, notarization,
# Sparkle appcast generation, GitHub Release publishing, and the Homebrew cask update.

set -euo pipefail

REPO="bysiber/cleardisk"
TAP_REPO="bysiber/homebrew-cleardisk"
CASK_PATH="Casks/cleardisk.rb"
APP_NAME="ClearDisk"
BUNDLE_ID="com.cleardisk.app"

_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$_LIB_DIR")"
SCRIPTS_DIR="$_LIB_DIR"
DIST_DIR="$ROOT_DIR/dist"

info() { printf '\033[34m==>\033[0m %s\n' "$*"; }
ok()   { printf '\033[32m ✓ \033[0m%s\n' "$*"; }
warn() { printf '\033[33m ! \033[0m%s\n' "$*" >&2; }
die()  { printf '\033[31m ✗ %s\033[0m\n' "$*" >&2; exit 1; }

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "'$1' is required but not installed."
}

# The version is declared in exactly one place — the first ## [X.Y.Z] heading in
# CHANGELOG.md — and everything else reads it back from there. That is what keeps the
# bundle, the DMG filename, the git tag, the GitHub release and the Homebrew cask from
# ever disagreeing with each other.
project_version() {
    local v
    v=$(awk '/^## \[/{gsub(/[\[\]]/, "", $2); print $2; exit}' "$ROOT_DIR/CHANGELOG.md")
    [ -n "$v" ] || die "Could not read version from CHANGELOG.md"
    [[ "$v" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] \
        || die "Invalid release version '$v' in CHANGELOG.md (expected X.Y.Z)."
    printf '%s' "$v"
}

dmg_path() { printf '%s/%s-v%s.dmg' "$DIST_DIR" "$APP_NAME" "$1"; }

# Pulls the section for one version out of CHANGELOG.md, so release notes are never
# hand-written twice.
changelog_section() {
    local version="$1"
    awk -v ver="$version" '
        $0 ~ "^## \\[" ver "\\]" { found = 1; next }
        found && /^## \[/        { exit }
        found                    { print }
    ' "$ROOT_DIR/CHANGELOG.md" | sed -e '/./,$!d'
}
