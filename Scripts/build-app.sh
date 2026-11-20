#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."
project="$PWD"
app="$project/dist/QuotaRail.app"
cache="$project/.build/module-cache"
mkdir -p "$cache" "$app/Contents/MacOS" "$app/Contents/Resources"

sdk="$(xcrun --sdk macosx --show-sdk-path)"
for arch in arm64 x86_64; do
    xcrun swiftc -sdk "$sdk" -target "$arch-apple-macosx13.0" -swift-version 5 \
        -module-cache-path "$cache" -parse-as-library -O -lsqlite3 Sources/QuotaRail/*.swift \
        -o "$project/.build/QuotaRail-$arch"
done
xcrun lipo -create "$project/.build/QuotaRail-arm64" "$project/.build/QuotaRail-x86_64" \
    -output "$app/Contents/MacOS/QuotaRail"

cp Scripts/Info.plist "$app/Contents/Info.plist"
cp LICENSE "$app/Contents/Resources/LICENSE"
ditto Resources "$app/Contents/Resources"
iconset="$project/.build/QuotaRail.iconset"
mkdir -p "$iconset"
xcrun swift -module-cache-path "$cache" Scripts/render-icon.swift "$iconset"
xcrun iconutil -c icns "$iconset" -o "$app/Contents/Resources/QuotaRail.icns"
codesign --force --sign - "$app"
codesign --verify --strict "$app"
rm -f "$project/dist/QuotaRail-macOS.zip"
ditto -c -k --norsrc --keepParent "$app" "$project/dist/QuotaRail-macOS.zip"
printf '%s\n' "$app"
