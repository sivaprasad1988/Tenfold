#!/bin/bash
# Builds a shareable Tenfold zip (no Apple Developer ID needed – ad-hoc signed).
# Output: dist/Tenfold-<version>.zip  (contains Tenfold.app + Install-Tenfold.txt)
set -euo pipefail
cd "$(dirname "$0")"

if [ -z "${DEVELOPER_DIR:-}" ] && [ -d /Applications/Xcode.app/Contents/Developer ]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Resources/Info.plist)
OUT="dist/Tenfold-$VERSION"
APP="$OUT/Tenfold.app"
rm -rf "$OUT" "dist/Tenfold-$VERSION.zip"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# Universal binary (Apple Silicon + Intel); falls back to this Mac's architecture if Intel fails.
BINARIES=()
for ARCH in arm64 x86_64; do
    if swift build -c release --arch "$ARCH"; then
        BINARIES+=("$(swift build -c release --arch "$ARCH" --show-bin-path)/Tenfold")
    else
        echo "⚠️  Build for $ARCH failed – skipping this architecture."
    fi
done
[ ${#BINARIES[@]} -gt 0 ] || { echo "❌ No architecture built"; exit 1; }
lipo -create "${BINARIES[@]}" -output "$APP/Contents/MacOS/Tenfold"

cp Resources/Info.plist "$APP/Contents/Info.plist"
cp -R Resources/*.lproj "$APP/Contents/Resources/"
xattr -cr "$APP"
codesign --force --deep --sign - "$APP"

cp Install-Tenfold.txt "$OUT/"
ditto -c -k --keepParent "$OUT" "dist/Tenfold-$VERSION.zip"

echo "✅ dist/Tenfold-$VERSION.zip  ($(lipo -archs "$APP/Contents/MacOS/Tenfold"))"
