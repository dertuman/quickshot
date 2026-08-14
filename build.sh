#!/bin/zsh
set -e
cd "$(dirname "$0")"

APP=build/QuickShot.app
rm -rf build
mkdir -p "$APP/Contents/MacOS"

swiftc -O -swift-version 5 -o "$APP/Contents/MacOS/QuickShot" Sources/main.swift
cp Info.plist "$APP/Contents/Info.plist"
# A stable signing identity keeps the Screen Recording grant across rebuilds.
# Falls back to ad-hoc if no Apple Development certificate exists.
IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Apple Development/{print $2; exit}')
codesign --force --sign "${IDENTITY:--}" "$APP"

echo "Built $APP"
