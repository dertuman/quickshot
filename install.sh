#!/bin/zsh
set -e
cd "$(dirname "$0")"

if ! xcode-select -p >/dev/null 2>&1; then
  echo "The Xcode Command Line Tools are required. Installing..."
  xcode-select --install
  echo "Finish the installer that just opened, then run ./install.sh again."
  exit 1
fi

echo "Building..."
./build.sh
ditto build/QuickShot.app /Applications/QuickShot.app
open /Applications/QuickShot.app

echo ""
echo "QuickShot is running (camera icon in the menu bar)."
echo "Press option cmd right-arrow, then grant Screen Recording when macOS asks."
