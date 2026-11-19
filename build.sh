#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

destination="$PWD/build"
mkdir -p "$destination"
staging="$(mktemp -d "$destination/.package.XXXXXX")"
trap 'rm -rf "$staging"' EXIT
bundle="$staging/Paperframe.app"
mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources"

if [[ "${1:-}" == --universal ]]; then
    for arch in arm64 x86_64; do
        swiftc -O -target "$arch-apple-macosx13.0" -o "$staging/PaperTypewriter-$arch" Sources/*.swift
    done
    lipo -create "$staging/PaperTypewriter-arm64" "$staging/PaperTypewriter-x86_64" \
        -output "$bundle/Contents/MacOS/PaperTypewriter"
else
    swiftc -O -target "$(uname -m)-apple-macosx13.0" \
        -o "$bundle/Contents/MacOS/PaperTypewriter" Sources/*.swift
fi
cp Info.plist "$bundle/Contents/Info.plist"
cp Assets/* "$bundle/Contents/Resources/"
cp 资源与授权.txt "$bundle/Contents/Resources/"
cp LICENSE "$bundle/Contents/Resources/"
codesign --force --sign - "$bundle"
codesign --verify --strict "$bundle"
ditto "$bundle" "$destination/Paperframe.app"
printf '%s\n' "$destination/Paperframe.app"
