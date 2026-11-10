#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
app="build/Android USB.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" build/swift-cache
cp Studio.icns "$app/Contents/Resources/Studio.icns"
cp Info.plist "$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleExecutable AndroidUSB" "$app/Contents/Info.plist"
swiftc -swift-version 6 -parse-as-library -module-cache-path build/swift-cache AndroidUSB.swift -o "$app/Contents/MacOS/AndroidUSB"
codesign --force --sign - "$app"
