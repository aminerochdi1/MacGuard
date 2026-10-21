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
