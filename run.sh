#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

app="build/Phone Studio.app"
executable="$app/Contents/MacOS/AndroidUSB"
if [[ ! -x "$executable" || ! -f "$app/Contents/Info.plist" ||
      Info.plist -nt "$executable" ||
      Studio.icns -nt "$executable" || ! -f "$app/Contents/Resources/Studio.icns" ||
      VERSION -nt "$executable" || build.sh -nt "$executable" ]] ||
   [[ -n "$(find Sources -newer "$executable" -print -quit)" ]]; then
    ./build.sh
fi

target="$app"
if [[ "${1:-}" == "--install" ]]; then
    install_dir="$HOME/Applications"
    target="$install_dir/Phone Studio.app"
    mkdir -p "$install_dir"
    if [[ -e "$target" ]]; then
        identifier=$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$target/Contents/Info.plist")
        [[ "$identifier" == "local.android-usb" ]] || exit 1
    fi
    staging=$(mktemp -d "$install_dir/.phone-studio-update.XXXXXX")
    trap 'rm -rf "$staging"' EXIT
    ditto "$app" "$staging/Phone Studio.app"
    /usr/libexec/PlistBuddy -c 'Add :StudioLocalSource string' "$staging/Phone Studio.app/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Set :StudioLocalSource $PWD" "$staging/Phone Studio.app/Contents/Info.plist"
    codesign --force --sign - "$staging/Phone Studio.app"
    codesign --verify --strict "$staging/Phone Studio.app"
fi

swift -module-cache-path build/swift-cache - <<'SWIFT'
import AppKit

let apps = NSRunningApplication.runningApplications(withBundleIdentifier: "local.android-usb")
for app in apps {
    _ = app.terminate()
}
let deadline = Date().addingTimeInterval(5)
while apps.contains(where: { !$0.isTerminated }) && Date() < deadline {
    RunLoop.current.run(until: Date().addingTimeInterval(0.1))
}
guard apps.allSatisfy(\.isTerminated) else {
    print("旧实例尚未退出，请先退出 App，再重试。")
    exit(1)
}
print("已退出 \(apps.count) 个旧实例。")
SWIFT

if [[ "${1:-}" == "--install" ]]; then
    if [[ -e "$target" ]]; then
        mv "$target" "$staging/previous.app"
    fi
    if ! mv "$staging/Phone Studio.app" "$target"; then
        if [[ -e "$staging/previous.app" ]]; then
            mv "$staging/previous.app" "$target" || { trap - EXIT; exit 1; }
        fi
        exit 1
    fi
fi
open "$target"
