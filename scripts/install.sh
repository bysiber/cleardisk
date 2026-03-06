#!/bin/bash
# Install ClearDisk from local build - builds, creates DMG, installs to /Applications
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CD_ROOT="$(dirname "$SCRIPT_DIR")"
cd "$CD_ROOT"

echo "Building ClearDisk..."
bash scripts/build_app.sh 2>&1 | tail -3

echo "Stopping existing ClearDisk..."
pkill -f ClearDisk 2>/dev/null || true
sleep 1

echo "Installing to /Applications..."
rm -rf /Applications/ClearDisk.app
cp -R ClearDisk.app /Applications/

echo "Clearing quarantine flag..."
xattr -cr /Applications/ClearDisk.app

echo "Launching ClearDisk..."
open /Applications/ClearDisk.app

echo "Done. ClearDisk is running in your menu bar."
