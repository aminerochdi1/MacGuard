#!/bin/bash
# Usage: tools/release.sh            -> build and zip the app into dist/
#        tools/release.sh --publish  -> also create a GitHub release for the current version (needs `gh auth login`)
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Info.plist)
TAG="v$VERSION"
ZIP="MacGuard-$VERSION.zip"

./build.sh

mkdir -p dist
rm -f "dist/$ZIP" "dist/$ZIP.sha256"
ditto -c -k --keepParent build/MacGuard.app "dist/$ZIP"
(cd dist && shasum -a 256 "$ZIP" > "$ZIP.sha256")

# Release notes = this version's section of CHANGELOG.md (## 0.5 for 0.5.x) + install steps
SHORT="${VERSION%.*}"
NOTES_FILE="dist/release-notes-$VERSION.md"
{
    awk -v h="## $SHORT" '$0==h{f=1;next} /^## /{f=0} f' CHANGELOG.md
    cat <<'EON'

### Install
1. Download the zip, unzip it, and drag MacGuard.app to Applications.
2. First launch: right-click the app and choose Open (the app is not notarized by Apple).
   If macOS still blocks it: `xattr -dr com.apple.quarantine /Applications/MacGuard.app`
3. Apple Silicon (M1 to M4), macOS 13 or later.

Verify the download: `shasum -a 256 -c MacGuard-VERSION.zip.sha256`
EON
} | sed "s/VERSION/$VERSION/" > "$NOTES_FILE"

# Homebrew cask for this version (goes into the tap repo aminerochdi1/homebrew-macguard)
SHA=$(cut -d' ' -f1 "dist/$ZIP.sha256")
sed -e "s/__VERSION__/$VERSION/" -e "s/__SHA256__/$SHA/" homebrew/macguard.rb.template > dist/macguard.rb

echo
echo "Built: dist/$ZIP"
echo "Cask:  dist/macguard.rb"
echo "SHA-256: $(cut -d' ' -f1 "dist/$ZIP.sha256")"
echo "Notes: $NOTES_FILE"

if [ "${1:-}" = "--publish" ]; then
    command -v gh >/dev/null || { echo "gh (GitHub CLI) not found: brew install gh && gh auth login"; exit 1; }
    if [ -n "$(git status --porcelain)" ]; then
        echo "You have uncommitted changes. Commit and push first: tools/ship.sh \"message\""
        exit 1
    fi
    git push
    gh release create "$TAG" "dist/$ZIP" "dist/$ZIP.sha256" --title "MacGuard $VERSION" --notes-file "$NOTES_FILE"
    echo "Released $TAG"

    # Update the Homebrew tap if you have it cloned: export MACGUARD_TAP_DIR=~/path/to/homebrew-macguard
    if [ -n "${MACGUARD_TAP_DIR:-}" ] && [ -d "$MACGUARD_TAP_DIR" ]; then
        mkdir -p "$MACGUARD_TAP_DIR/Casks"
        cp dist/macguard.rb "$MACGUARD_TAP_DIR/Casks/macguard.rb"
        (cd "$MACGUARD_TAP_DIR" && git add -A && git commit -m "macguard $VERSION" && git push)
        echo "Homebrew tap updated."
    else
        echo "Homebrew: copy dist/macguard.rb to Casks/macguard.rb in your homebrew-macguard repo (or set MACGUARD_TAP_DIR)."
    fi
else
    echo "Not published. To publish: tools/release.sh --publish"
fi
