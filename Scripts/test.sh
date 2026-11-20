#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."
cache="$PWD/.build/module-cache"
app="$PWD/.build/QuotaRailTests.app"
mkdir -p "$cache" "$app/Contents/MacOS" "$app/Contents/Resources"
cp Scripts/Info.plist "$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier pl.poplogic.quotarail.tests' "$app/Contents/Info.plist"
ditto Resources "$app/Contents/Resources"
xcrun swiftc -target "$(uname -m)-apple-macosx13.0" -swift-version 5 \
    -module-cache-path "$cache" -parse-as-library -lsqlite3 \
    Sources/QuotaRail/{CLI,Localization,MenuBarReadout,Models,QuotaParsers,Store,Usage}.swift Tests/Smoke.swift \
    -o "$app/Contents/MacOS/QuotaRail"
for language in en pl; do
    "$app/Contents/MacOS/QuotaRail" -AppleLanguages "($language)" "$language"
done
