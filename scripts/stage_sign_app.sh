#!/bin/bash
# Sign away from synced folders; preserve the input bundle until replacement is verified.
set -euo pipefail

APP_BUNDLE="${1:?Usage: stage_sign_app.sh /absolute/path/App.app}"
[[ "$APP_BUNDLE" = /* && -d "$APP_BUNDLE" ]] || exit 1
APP_PARENT="$(dirname "$APP_BUNDLE")"
APP_LEAF="$(basename "$APP_BUNDLE")"
STAGE_DIR=""
REPLACE_DIR=""
BACKUP_DIR=""
COMMITTED=0

cleanup() {
    local status=$?
    trap - EXIT
    if [ "$COMMITTED" -eq 0 ] && [ -n "$BACKUP_DIR" ] && [ -d "$BACKUP_DIR/$APP_LEAF" ]; then
        rm -rf "$APP_BUNDLE"
        if ! mv "$BACKUP_DIR/$APP_LEAF" "$APP_BUNDLE"; then
            echo "error: restore failed; original bundle retained at $BACKUP_DIR/$APP_LEAF" >&2
            BACKUP_DIR=""
            status=1
        fi
    fi
    [ -z "$STAGE_DIR" ] || rm -rf "$STAGE_DIR"
    [ -z "$REPLACE_DIR" ] || rm -rf "$REPLACE_DIR"
    [ -z "$BACKUP_DIR" ] || rm -rf "$BACKUP_DIR"
    exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

STAGE_DIR="$(mktemp -d /tmp/cleardisk-sign.XXXXXX)"
ditto "$APP_BUNDLE" "$STAGE_DIR/$APP_LEAF"
xattr -cr "$STAGE_DIR/$APP_LEAF"
codesign --force --deep -s - "$STAGE_DIR/$APP_LEAF"
codesign --verify --deep --strict "$STAGE_DIR/$APP_LEAF"

# All fallible copying happens before the old bundle is moved. Sibling paths allow renames.
REPLACE_DIR="$(mktemp -d "$APP_PARENT/.cleardisk-replace.XXXXXX")"
ditto "$STAGE_DIR/$APP_LEAF" "$REPLACE_DIR/$APP_LEAF"
codesign --verify --deep --strict "$REPLACE_DIR/$APP_LEAF"
BACKUP_DIR="$(mktemp -d "$APP_PARENT/.cleardisk-backup.XXXXXX")"
mv "$APP_BUNDLE" "$BACKUP_DIR/$APP_LEAF"
mv "$REPLACE_DIR/$APP_LEAF" "$APP_BUNDLE"
codesign --verify --deep --strict "$APP_BUNDLE"
COMMITTED=1
