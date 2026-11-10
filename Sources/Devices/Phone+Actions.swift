import AppKit
import SwiftUI

extension Phone {
    private func iosApps(_ arguments: [String]) {
        guard isIOS else { return }
        run("xcrun", ["devicectl", "device"] + arguments + ["--device", deviceID, "--timeout", "45"]) {
            code, data, error in
            let details = String(decoding: data, as: UTF8.self) + error
            self.status = (code == 0 ? "" : "iPhone 应用操作失败。请检查 Xcode、USB 信任和开发者模式。\n")
                + String(details.prefix(30_000))
        }
    }

    func listApps() {
        if isIOS {
            iosApps(["info", "apps"])
        } else {
            command(isHarmony ? ["shell", "bm", "dump", "-a"] :
                    ["shell", "pm", "list", "packages", "-3"])
        }
    }

    func command(_ arguments: [String]) {
        guard hasSelectedDevice, !isIOS else { return }
        let harmony = isHarmony
        let target = harmony ? ["-t", deviceID] : ["-d"]
        run(harmony ? "hdc" : "adb", target + arguments) { code, data, error in
            let output = String(decoding: data, as: UTF8.self)
            let details = (output + error).trimmingCharacters(in: .whitespacesAndNewlines)
            let packageOperation = arguments.first == "install" || arguments.first == "uninstall"
            // HDC reports bundle-manager failures in the output even when it exits with zero.
            let bundleFailure = harmony && packageOperation &&
                details.localizedCaseInsensitiveContains("msg:error:")
            if code != 0 || bundleFailure {
                self.status = "操作失败。\n" + String(details.prefix(30_000))
            } else {
                self.status = details.isEmpty ? "操作完成。" : String(details.prefix(30_000))
            }
        }
    }

    func install() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = (isIOS ? ["app"] : (isHarmony ? ["hap", "hsp"] : ["apk"]))
            .compactMap { .init(filenameExtension: $0) }
        if isIOS { panel.message = "选择已为这台 iPhone 签名的 iOS .app。 " }
        guard panel.runModal() == .OK, let file = panel.url else { return }
        if isIOS {
            iosApps(["install", "app", file.path])
        } else {
            command(["install", "-r", file.path])
        }
    }

    private func iosFileCopy(toDevice: Bool, source: String, destination: String) {
        iosApps(["copy", toDevice ? "to" : "from", "--domain-type", "temporary",
                 "--domain-identifier", "local.phone-usb-studio",
                 "--source", source, "--destination", destination])
    }

    func push() {
        let panel = NSOpenPanel()
        guard panel.runModal() == .OK, let file = panel.url else { return }
        if isIOS {
            iosFileCopy(toDevice: true, source: file.path, destination: file.lastPathComponent)
        } else if isHarmony {
            guard let path = ask("鸿蒙文件推送",
                                 prompt: "输入设备上的目标绝对路径。默认使用 HDC 可写的调试目录。",
                                 initial: "/data/local/tmp/" + file.lastPathComponent),
                  path.hasPrefix("/") else { return }
            command(["file", "send", file.path, path])
        } else {
            command(["push", file.path, "/sdcard/Download/"])
        }
    }

    func pull() {
        if isIOS {
            guard let name = ask("iPhone 文件获取", prompt: "输入此前推送到 Phone Studio 调试文件区的文件名。"),
                  !name.isEmpty, name != ".", name != "..", !name.contains("/") else { return }
            let panel = NSSavePanel()
            panel.directoryURL = preferredDirectory
            panel.nameFieldStringValue = name
            guard panel.runModal() == .OK, let destination = panel.url else { return }
            iosFileCopy(toDevice: false, source: name, destination: destination.path)
            return
        }
        guard let path = ask("文件获取", prompt: "输入手机上的绝对路径，例如 /sdcard/Download/example.txt"),
              path.hasPrefix("/") else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.directoryURL = preferredDirectory
        guard panel.runModal() == .OK, let directory = panel.url else { return }
        command(isHarmony ? ["file", "recv", path, directory.path] : ["pull", path, directory.path])
    }

    func uninstall() {
        guard let package = ask("卸载应用", prompt: "输入应用包名。卸载会移除应用及其数据。"),
              package.contains("."), package.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "_") })
        else { return }
        if isIOS {
            iosApps(["uninstall", "app", package])
        } else {
            command(["uninstall", package])
        }
    }
}
