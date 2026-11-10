# phone-usb-studio

macOS 上的 Android USB 投屏工具。用鼠标在 scrcpy 投屏窗口点击、长按或滑动，也可以从主窗口保存 PNG 截图。

## 构建和使用

需要 macOS 14 或以上、Swift 6 工具链和 Homebrew。

```sh
brew install scrcpy android-platform-tools
./build.sh
open "build/Android USB.app"
```

连接一台 Android 手机，开启 USB 调试并在手机上确认授权，然后点击「打开投屏」。截图保存在你选择的位置。
