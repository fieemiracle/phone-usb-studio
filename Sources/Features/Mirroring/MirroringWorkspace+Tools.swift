import AppKit
import SwiftUI

extension MirroringWorkspace {
    var tools: some View {
        ScrollView {
            VStack(spacing: 9) {
                ToolCard("按键区") {
                    HStack(spacing: 6) {
                        if phone.isIOS {
                            tile("锁屏", "lock") { phone.iosKey("lock") }
                            tile("主屏幕", "house") { phone.iosKey("home") }
                            tile("音量加", "speaker.plus") { phone.iosKey("volumeUp") }
                            tile("音量减", "speaker.minus") { phone.iosKey("volumeDown") }
                        } else {
                            tile("电源键", "power") { phone.command(phone.isHarmony ? ["shell", "uitest", "uiInput", "keyEvent", "Power"] :
                                ["shell", "input", "keyevent", "26"]) }
                            tile("返回", "arrow.left.circle") { phone.command(phone.isHarmony ? ["shell", "uitest", "uiInput", "keyEvent", "Back"] :
                                ["shell", "input", "keyevent", "4"]) }
                            tile("音量加", "speaker.plus") {
                                phone.command(phone.isHarmony ? ["shell", "uitest", "uiInput", "keyEvent", "16"] :
                                              ["shell", "input", "keyevent", "24"])
                            }
                            tile("音量减", "speaker.minus") {
                                phone.command(phone.isHarmony ? ["shell", "uitest", "uiInput", "keyEvent", "17"] :
                                              ["shell", "input", "keyevent", "25"])
                            }
                        }
                        Spacer(minLength: 0)

                    }
                }
                ToolCard("设备/应用信息") {
                    HStack(spacing: 6) {
                        tile("安装应用", "square.and.arrow.down", phone.install)
                        tile("卸载应用", "trash", phone.uninstall)
                        tile("应用信息", "square.grid.2x2", phone.listApps)
                    }
                }
                ToolCard("文件信息") {
                    HStack(spacing: 6) {
                        tile("文件推送", "square.and.arrow.up", phone.push)
                        tile("文件获取", "arrow.down.circle", phone.pull)
                        tile("日志获取", "doc.text", phone.exportLogs).disabled(phone.exportingLogs)
                    }
                }
                ToolCard("快捷操作") {
                    HStack(spacing: 6) {
                        tile("截屏", "camera.viewfinder", phone.screenshot).disabled(phone.saving)
                        tile(phone.recording ? "停止录制" : "屏幕录制",
                             phone.recording ? "stop.circle" : "video") {
                            if phone.recording { phone.stopRecording() } else { phone.startRecording() }
                        }

                    }
                }
                ToolCard("保存位置") {
                    HStack {
                        Text(phone.outputDirectory.isEmpty ? "下载文件夹" : phone.outputDirectory)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Button("更改目录…", action: phone.chooseOutputDirectory)
                    }
                }
                if !phone.isIOS {
                    ToolCard("自定义指令") {
                        HStack {
                            Text(phone.isHarmony ? "hdc shell" : "adb shell")
                            TextField("输入设备 shell 命令", text: $shellCommand)
                            Button("发送") { phone.command(["shell", shellCommand]) }
                                .buttonStyle(.borderedProminent)
                                .tint(blue)
                                .disabled(phone.deviceID.isEmpty || shellCommand.trimmingCharacters(in: .whitespaces).isEmpty)
                        }
                    }
                }
                ToolCard("执行日志") {
                    Button("清屏") { phone.status = "" }
                        .buttonStyle(.borderedProminent)
                        .tint(blue)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                    ScrollView {
                        Text(phone.status)
                            .font(.system(size: 12, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                            .padding(8)
                    }
                    .frame(height: 155)
                    .background(.white, in: RoundedRectangle(cornerRadius: 4))
                    .overlay { RoundedRectangle(cornerRadius: 4).strokeBorder(.black.opacity(0.13)).allowsHitTesting(false) }
                }
            }
        }
    }

    private func tile(_ title: String, _ icon: String, _ perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            VStack(spacing: 4) {
                Image(systemName: icon)
                Text(title).font(.system(size: 12)).lineLimit(1)
            }
            .frame(width: 56, height: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(phone.deviceID.isEmpty)
        .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(.black.opacity(0.10)).allowsHitTesting(false) }
    }
}
