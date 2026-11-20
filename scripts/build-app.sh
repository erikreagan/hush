#!/bin/bash
# Builds build/Hush.app. Signs with the "Hush Dev" certificate if present (see make-signing-cert.sh), else ad-hoc.
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release --product Hush
app=build/Hush.app
rm -rf "$app" && mkdir -p "$app/Contents/MacOS"
cp .build/release/Hush "$app/Contents/MacOS/"
cp App/Info.plist "$app/Contents/"
kc="$HOME/Library/Keychains/hush-signing.keychain-db"
if [ -f "$kc" ]; then
  security unlock-keychain -p hush "$kc"
  codesign --force --sign "Hush Dev" --keychain "$kc" "$app"
  echo "Built $app (signed: Hush Dev)"
else
  codesign --force --sign - "$app"
  echo "Built $app (signed ad-hoc)"
fi
