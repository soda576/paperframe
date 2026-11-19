#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

version=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Info.plist)
app=$(bash build.sh --universal)
staging=$(mktemp -d)
trap 'rm -rf "$staging"' EXIT
ditto "$app" "$staging/Paperframe.app"
ln -s /Applications "$staging/Applications"
mkdir -p dist
hdiutil create -ov -format UDZO -volname Paperframe -srcfolder "$staging" \
    "dist/Paperframe-$version-macOS-universal.dmg"
