#!/bin/zsh
# Usage: ./release.sh 1.1
set -e
cd "$(dirname "$0")"

VERSION=${1:?usage: ./release.sh <version>}
./build.sh
ditto -c -k --keepParent build/QuickShot.app build/QuickShot.zip
gh release create "v$VERSION" build/QuickShot.zip --title "QuickShot $VERSION" --notes "QuickShot $VERSION"

echo "Released v$VERSION"
