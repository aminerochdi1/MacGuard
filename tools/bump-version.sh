#!/bin/bash
# Usage: tools/bump-version.sh 0.6.0   -> sets the app version and increments the build number in Info.plist
set -euo pipefail
cd "$(dirname "$0")/.."
NEW="${1:?Usage: tools/bump-version.sh 0.6.0}"
BUILD=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" Info.plist)
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $NEW" Info.plist
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $((BUILD + 1))" Info.plist
echo "Version $NEW (build $((BUILD + 1)))."
echo "Next: add a '## ${NEW%.*}' section to CHANGELOG.md, then tools/release.sh"
