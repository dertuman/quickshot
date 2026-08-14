#!/bin/bash
set -e

echo "Downloading QuickShot..."
TMP=$(mktemp -d)
curl -fsSL https://github.com/dertuman/quickshot/releases/latest/download/QuickShot.zip -o "$TMP/QuickShot.zip"
ditto -x -k "$TMP/QuickShot.zip" "$TMP"
rm -rf /Applications/QuickShot.app
ditto "$TMP/QuickShot.app" /Applications/QuickShot.app
rm -rf "$TMP"
open /Applications/QuickShot.app

echo ""
echo "QuickShot is running (camera icon in the menu bar)."
echo "Press fn+ctrl, then allow Accessibility and Screen Recording when macOS asks."
