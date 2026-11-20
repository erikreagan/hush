#!/bin/bash
# Builds the BlackHole fork as "Hush": hidden output "Hush Feed" (UID Hush_UID)
# mirrored into visible input "Hush Mic" (UID Hush_2_UID). No driver code changes.
# Compiles the single C file directly with clang (no xcodebuild needed).
set -euo pipefail
cd "$(dirname "$0")/.."
src=Driver/blackhole/BlackHole
out=build/driver/Hush.driver
bundleID="com.erikreagan.hush.driver"
rm -rf "$out" && mkdir -p "$out/Contents/MacOS" "$out/Contents/Resources"
xcrun clang -bundle -arch arm64 -O2 -mmacosx-version-min=15.0 \
  -framework CoreAudio -framework CoreFoundation -framework Accelerate \
  -DkDriver_Name='"Hush"' -DkPlugIn_BundleID="\"$bundleID\"" -DkManufacturer_Name='"Hush"' \
  -DkHas_Driver_Name_Format=false -DkNumber_Of_Channels=2 -DkSampleRates=48000 \
  -DkDevice_Name='"Hush Feed"' -DkDevice_IsHidden=true -DkDevice_HasInput=false -DkDevice_HasOutput=true \
  -DkDevice2_Name='"Hush Mic"' -DkDevice2_IsHidden=false -DkDevice2_HasInput=true -DkDevice2_HasOutput=false \
  -o "$out/Contents/MacOS/Hush" "$src/BlackHole.c"
cp "$src/BlackHole.icns" "$out/Contents/Resources/"
sed -e 's/\${EXECUTABLE_NAME}/Hush/' -e 's/\${PRODUCT_NAME}/Hush/' \
    -e "s/\$(PRODUCT_BUNDLE_IDENTIFIER)/$bundleID/" -e 's/\$(MARKETING_VERSION)/1.0/' \
    "$src/BlackHole.plist" > "$out/Contents/Info.plist"
codesign --force --sign - "$out"
echo "Built $out"
