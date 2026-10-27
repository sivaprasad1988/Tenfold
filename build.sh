#!/bin/bash
# Builds Tenfold.app into ./build (requires Xcode or the Command Line Tools on macOS).
set -euo pipefail
cd "$(dirname "$0")"

# Prefer full Xcode if installed (the Command Line Tools lack the SwiftUI macro plugins).
if [ -z "${DEVELOPER_DIR:-}" ] && [ -d /Applications/Xcode.app/Contents/Developer ]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
echo "Toolchain: ${DEVELOPER_DIR:-$(xcode-select -p)}"

swift build -c release

APP="build/Tenfold.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/Tenfold "$APP/Contents/MacOS/Tenfold"
cp Resources/Info.plist "$APP/Contents/Info.plist"
mkdir -p "$APP/Contents/Resources"
cp -R Resources/*.lproj "$APP/Contents/Resources/"   # localized permission texts
codesign --force --sign - "$APP"   # ad-hoc signature for local use

echo "Built $APP  ->  run with: open $APP"
