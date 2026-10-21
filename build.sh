#!/bin/bash
# Builds MacGuard.app with Command Line Tools only (no Xcode).
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release

APP="build/MacGuard.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/MacGuard "$APP/Contents/MacOS/MacGuard"
cp Info.plist "$APP/Contents/Info.plist"

# App icon (iconutil ships with macOS)
if [ -d Resources/AppIcon.iconset ]; then
    iconutil -c icns Resources/AppIcon.iconset -o "$APP/Contents/Resources/AppIcon.icns"
fi

codesign --force --sign - "$APP"

echo "Built: $APP"
echo "Run:   open $APP"
echo "Check data accuracy: $APP/Contents/MacOS/MacGuard --selftest"
