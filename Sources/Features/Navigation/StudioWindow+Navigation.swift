import AppKit
import SwiftUI

extension StudioWindow {
    var directory: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Phone Studio")
                    .font(.system(size: 20, weight: .bold))
                    .lineLimit(1)
                Spacer(minLength: 4)
            }
            .padding(.bottom, 12)

            navigation("首页", icon: "house", destination: .home, selected: page == .home)
            navigation("实用工具", icon: "wrench.and.screwdriver",
                       destination: .utilities, selected: page != .home)
            Spacer()
            if Bundle.main.object(forInfoDictionaryKey: "StudioLocalSource") != nil {
                Button(action: LocalAppUpdater.install) {
                    Label("升级并重启", systemImage: "arrow.clockwise")
                        .font(.system(size: 14, weight: .semibold))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .background(.white.opacity(0.16), in: RoundedRectangle(cornerRadius: 8))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("从本地项目构建新版并重启")
            }
        }
        .foregroundStyle(.white)
        .padding(16)
        .frame(width: 200)
        .background(LinearGradient(colors: [blue, Color(red: 0.36, green: 0.67, blue: 0.96)], startPoint: .top, endPoint: .bottom))
    }

    private func navigation(_ title: String, icon: String, destination: Page,
                            selected: Bool) -> some View {
        Button {
            page = destination
        } label: {
            Label(title, systemImage: icon)
                .font(.system(size: 16, weight: .semibold))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .foregroundStyle(selected ? blue : .white)
                .background(.white.opacity(selected ? 1 : 0),
                            in: RoundedRectangle(cornerRadius: 8))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    var landing: some View {
        VStack(alignment: .leading, spacing: 18) {
            let home = page == .home
            ToolCard(nil) {
                Text(home ? "通过 USB 连接 Android 或鸿蒙手机，在 Mac 上查看和操作设备。"
                          : "选择一个工具开始操作已连接的手机。")
                    .foregroundStyle(.secondary)
            }
            Button {
                page = home ? .utilities : .mirroring
            } label: {
                ToolCard(home ? "实用工具" : "设备投屏") {
                    HStack(spacing: 14) {
                        Image(systemName: home ? "wrench.and.screwdriver" : "iphone")
                            .font(.title2)
                            .foregroundStyle(.teal)
                            .frame(width: 42, height: 42)
                            .background(.teal.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
                        Text(home ? "浏览设备工具" : "查看手机画面，支持触控、截图、录屏和日志导出。")
                            .font(.callout)
                            .multilineTextAlignment(.leading)
                        Spacer()
                        Image(systemName: "arrow.up.right")
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .frame(maxWidth: 370, alignment: .leading)
            Spacer()
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.regularMaterial)
    }
}
