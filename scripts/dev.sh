#!/bin/bash
# ClearDisk dev script - build .app bundle, kill old, launch new
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$(dirname "$SCRIPT_DIR")"

echo ">> Killing old ClearDisk..."
pkill -f "ClearDisk" 2>/dev/null || true
sleep 0.5

echo ">> Building .app bundle..."
"$SCRIPT_DIR/build_app.sh"

echo ">> Launching..."
open ClearDisk.app

echo ">> Done! Check menu bar."
