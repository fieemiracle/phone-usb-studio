# phone-usb-studio

macOS 上的 Android USB 投屏工具。中间显示手机画面，可点击或拖动。右侧提供 PNG 截图、无声 MP4 录屏和 Logcat 缓冲区导出。

## 构建和使用

需要 macOS 14 或以上、Swift 6 工具链和 Homebrew。

```sh
brew install scrcpy android-platform-tools
./build.sh
open "build/Android USB.app"
```

连接一台 Android 手机，开启 USB 调试并在手机上确认授权，然后进入「实用工具 → 设备投屏」，点击「开始投屏」。截图保存在你选择的位置。

## 用 Xcode 运行

安装上面的 Homebrew 依赖后，打开 `PhoneUSBStudio.xcodeproj`，选中 `PhoneUSBStudio → My Mac`，按 **⌘R**。
用 USB 数据线连接一台已授权 USB 调试的 Android 手机，进入「实用工具 → 设备投屏」后点击「开始投屏」。在中间画面点击或拖动，在右侧点击「保存截图…」保存 PNG。
