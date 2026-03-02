#!/bin/bash
# ClearDisk dev script - build .app bundle, kill old, launch new
set -e

echo ">> Killing old ClearDisk..."
pkill -f "ClearDisk" 2>/dev/null || true
sleep 0.5

echo ">> Building .app bundle..."
./build_app.sh

echo ">> Launching..."
open ClearDisk.app

echo ">> Done! Check menu bar."
