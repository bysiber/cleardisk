#!/bin/bash
# Uninstall ClearDisk completely - removes app, preferences, caches, and Gatekeeper approval
set -e

echo "Stopping ClearDisk..."
pkill -f ClearDisk 2>/dev/null || true
sleep 1

echo "Removing app bundles..."
rm -rf /Applications/ClearDisk.app
rm -rf ~/Applications/ClearDisk.app

echo "Removing preferences and caches..."
defaults delete com.cleardisk.app 2>/dev/null || true
defaults delete com.bysiber.ClearDisk 2>/dev/null || true
rm -f ~/Library/Preferences/com.cleardisk.app.plist
rm -f ~/Library/Preferences/com.bysiber.ClearDisk.plist
rm -rf ~/Library/Caches/com.cleardisk.app
rm -rf ~/Library/Caches/com.bysiber.ClearDisk

echo "Resetting Gatekeeper approval..."
tccutil reset All com.cleardisk.app 2>/dev/null || true

echo "Removing Gatekeeper assessment cache..."
spctl --remove /Applications/ClearDisk.app 2>/dev/null || true

echo "Removing launch agents (if any)..."
rm -f ~/Library/LaunchAgents/com.cleardisk.app.plist 2>/dev/null || true
rm -f ~/Library/LaunchAgents/com.bysiber.ClearDisk.plist 2>/dev/null || true

echo "Done. ClearDisk fully removed (app, preferences, caches, permissions, Gatekeeper)."
