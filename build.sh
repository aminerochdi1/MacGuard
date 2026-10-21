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

# Sign with the stable local identity if it exists (keeps macOS permissions between builds)
IDENTITY="MacGuard Local Signing"
if security find-identity -v -p codesigning 2>/dev/null | grep -q "$IDENTITY"; then
    codesign --force --sign "$IDENTITY" "$APP"
    echo "Signed with: $IDENTITY"
else
    codesign --force --sign - "$APP"
    echo "Signed ad-hoc. Run tools/setup-signing.sh once for a stable identity."
fi

echo "Built: $APP"
echo "Run:   ./run.sh   (or: open $APP)"
echo "Check data accuracy: $APP/Contents/MacOS/MacGuard --selftest"
