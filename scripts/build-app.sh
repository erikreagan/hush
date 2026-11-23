#!/bin/bash
# Builds build/Hush.app. Signs with the "Hush Dev" certificate if present (see make-signing-cert.sh), else ad-hoc.
set -euo pipefail
cd "$(dirname "$0")/.."
[ -f build/dfn/libdf.a ] || scripts/build-dfn.sh
swift build -c release --product Hush
app=build/Hush.app
rm -rf "$app" && mkdir -p "$app/Contents/MacOS"
cp .build/release/Hush "$app/Contents/MacOS/"
cp App/Info.plist "$app/Contents/"
mkdir -p "$app/Contents/Resources" && cp build/dfn/DeepFilterNet3_onnx.tar.gz App/AppIcon.icns "$app/Contents/Resources/"
# SwiftPM stamps the binary as built with the macOS 15 SDK, which makes macOS draw the app in its
# legacy look (small window corners, old-style controls). Stamp the SDK we actually built with.
xcrun vtool -set-build-version macos 15.0 "$(xcrun --show-sdk-version)" -replace \
  -output "$app/Contents/MacOS/Hush" "$app/Contents/MacOS/Hush"
kc="$HOME/Library/Keychains/hush-signing.keychain-db"
if [ -f "$kc" ]; then
  security unlock-keychain -p hush "$kc"
  codesign --force --sign "Hush Dev" --keychain "$kc" "$app"
  echo "Built $app (signed: Hush Dev)"
else
  codesign --force --sign - "$app"
  echo "Built $app (signed ad-hoc)"
fi
