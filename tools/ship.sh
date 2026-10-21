#!/bin/bash
# Usage: tools/ship.sh "what changed"   -> commit everything and push to GitHub
set -euo pipefail
cd "$(dirname "$0")/.."
MSG="${1:-Update $(date '+%Y-%m-%d %H:%M')}"
git add -A
if git diff --cached --quiet; then
    echo "Nothing to commit."
    exit 0
fi
git commit -m "$MSG"
git push
