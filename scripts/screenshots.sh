#!/bin/bash
# Regenerates site/screenshots from the app's --snapshot mode (see SPEC.md). Run after scripts/build-app.sh.
# Usage: scripts/screenshots.sh [path to Hush binary]
set -euo pipefail
cd "$(dirname "$0")/.."
tmp=$(mktemp -d)
"${1:-build/Hush.app/Contents/MacOS/Hush}" --snapshot "$tmp/x.png"
rm -rf site/screenshots && mkdir -p site/screenshots
rm "$tmp/x.png" "$tmp/x-menubar.png"   # developer contact sheets, not website material
for f in "$tmp"/x-*.png; do cp "$f" "site/screenshots/${f##*/x-}"; done
rm -rf "$tmp"
ls site/screenshots
