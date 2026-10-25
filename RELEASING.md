# Releasing MacGuard (maintainer notes)

```bash
tools/bump-version.sh 0.6.0      # set the version, then add a "## 0.6" section to CHANGELOG.md
tools/ship.sh "message"          # commit and push
tools/release.sh --publish       # build, zip, checksum, create the GitHub release
```

- `tools/release.sh` on its own only builds the zip into `dist/` (nothing is published).
- Publishing needs the GitHub CLI: `brew install gh && gh auth login`, and a clean working tree (commit and push first).
- Release notes come from the matching `## x.y` section of `CHANGELOG.md`.
- The app is not notarized, so the release notes tell users to right-click > Open the first time.

## Homebrew tap (one-time setup)
1. On GitHub create an empty public repo named `homebrew-macguard` (the name must start with `homebrew-`).
2. Clone it: `git clone https://github.com/aminerochdi1/homebrew-macguard.git ~/homebrew-macguard`
3. Add `export MACGUARD_TAP_DIR=~/homebrew-macguard` to your `~/.zshrc`.

After that, `tools/release.sh --publish` also writes `Casks/macguard.rb` into the tap, commits and pushes it. Without `MACGUARD_TAP_DIR`, copy `dist/macguard.rb` to `Casks/macguard.rb` in the tap yourself.

Test: `brew install --cask aminerochdi1/macguard/macguard` (needs the release zip to exist first).
The cask removes the quarantine flag because MacGuard is not notarized.
