# phone-usb-studio

macOS 上的 Android USB 投屏工具。中间显示手机画面，可点击或拖动。右侧提供 PNG 截图、无声 MP4 录屏和 Logcat 缓冲区导出。

## 构建和使用

需要 macOS 14 或以上、Swift 6 工具链和 Homebrew。

```sh
brew install scrcpy android-platform-tools
./run.sh
```

连接一台 Android 手机，开启 USB 调试并在手机上确认授权，然后进入「实用工具 → 设备投屏」，点击「开始投屏」。截图保存在你选择的位置。

## 用 Xcode 运行

安装上面的 Homebrew 依赖后，打开 `PhoneUSBStudio.xcodeproj`，选中 `PhoneUSBStudio → My Mac`，按 **⌘R**。
用 USB 数据线连接一台已授权 USB 调试的 Android 手机，进入「实用工具 → 设备投屏」后点击「开始投屏」。在中间画面点击或拖动，在右侧点击「保存截图…」保存 PNG。

## 鸿蒙 USB 预览

安装 DevEco Studio 的 HDC 工具，并确保 `hdc list targets -v` 能看到已授权的 USB 设备。
应用从 Homebrew 常用目录或 `~/.local/lib/hdc/<版本>/` 查找 HDC。进入「实用工具 → 设备投屏」，从设备下拉菜单选择鸿蒙设备。
鸿蒙支持点击、滑动、PNG 截图、HiLog、HAP/HSP 安装、应用卸载和 HDC 文件传输。鸿蒙录屏使用 JPEG 采样生成约 1 FPS 的无声 MP4，需要安装 FFmpeg（`brew install ffmpeg`）。

在投屏页右侧的「保存位置」中可修改截图、日志、录屏和文件获取的默认保存目录。Android 日志导出 Logcat 的 main、system、crash 缓冲区，鸿蒙导出当前 HiLog 缓冲区。

## iPhone USB

通过 USB 连接并信任这台 Mac。设备识别需要 `brew install libimobiledevice`，投屏首次启动需要允许 macOS 摄像头权限。投屏后可截屏，也可用 FFmpeg 录制约 10 FPS 的无声 MP4。文件推送和获取使用 Phone Studio 的独立调试文件区，获取时输入此前推送的文件名。

点击、拖动、主屏幕、锁屏和音量键需要 WebDriverAgent。用 Xcode 为目标 iPhone 签名并运行 Appium 的 WebDriverAgentRunner 测试，让它在手机的 8100 端口监听。保持测试运行，App 会用 `iproxy` 从本机通过 USB 连接。安装和卸载 iOS 应用使用 Xcode 的 devicectl，安装要求为该手机签名的 iOS .app。
