#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

version="${1#v}"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "Usage: $0 vX.Y.Z" >&2; exit 2; }
output_dir="${2:-build/release}"
mkdir -p "$output_dir"
temp_dir=$(mktemp -d)
trap 'rm -rf "$temp_dir"' EXIT

xcodebuild -project PhoneUSBStudio.xcodeproj -scheme PhoneUSBStudio \
    -configuration Release -destination 'generic/platform=macOS' \
    -derivedDataPath "$temp_dir/derived" ARCHS='arm64 x86_64' ONLY_ACTIVE_ARCH=NO build

mkdir "$temp_dir/image"
app="$temp_dir/image/Phone USB Studio.app"
ditto "$temp_dir/derived/Build/Products/Release/Android USB.app" "$app"
/usr/libexec/PlistBuddy -c "Add :CFBundleShortVersionString string $version" "$app/Contents/Info.plist"
codesign --force --sign - "$app"
codesign --verify --strict "$app"
lipo "$app/Contents/MacOS/Android USB" -verify_arch arm64 x86_64
ln -s /Applications "$temp_dir/image/Applications"

image="$output_dir/Phone-USB-Studio-v$version-macOS-universal.dmg"
hdiutil create -ov -volname "Phone USB Studio" -srcfolder "$temp_dir/image" -format UDZO "$image"
hdiutil verify "$image"
