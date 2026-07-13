#!/bin/bash
# Shared helpers for the release scripts. Source this, don't run it.
#
#   do_dmg.sh       build the .app and package dist/ClearDisk-v<version>.dmg
#   do_gh.sh        tag + publish the GitHub release with that DMG attached
#   brew_update.sh  point the Homebrew cask at the published DMG
#
# Run them in that order. The cask points at the release URL, so the DMG must be
# uploaded before the cask is updated or `brew install` 404s.

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

# The version is declared in exactly one place — VERSION= in build_app.sh — and everything
# else reads it back from there. That is what keeps the bundle, the DMG filename, the git
# tag, the GitHub release and the Homebrew cask from ever disagreeing with each other.
project_version() {
    local v
    v=$(grep -m1 -E '^VERSION="[^"]+"' "$SCRIPTS_DIR/build_app.sh" \
        | sed -E 's/^VERSION="([^"]+)".*/\1/')
    [ -n "$v" ] || die "Could not read VERSION from scripts/build_app.sh"
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
