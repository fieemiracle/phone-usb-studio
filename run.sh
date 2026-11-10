#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

./build.sh

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

open "build/Android USB.app"
