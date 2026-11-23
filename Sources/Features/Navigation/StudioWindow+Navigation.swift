import AppKit
import SwiftUI

extension StudioWindow {
    var directory: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Phone Studio")
                    .font(.system(size: 17, weight: .semibold))
                    .lineLimit(1)
                Spacer(minLength: 4)
            }
            .padding(.bottom, 12)

            navigation("首页", icon: "house", destination: .home, selected: page == .home)
            navigation("实用工具", icon: "wrench.and.screwdriver",
                       destination: .utilities, selected: page == .utilities || page == .mirroring)
            navigation("设备调试", icon: "terminal", destination: .debugging, selected: page == .debugging)
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
        .foregroundStyle(Color.primary)
        .padding(16)
        .frame(width: 200)
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay(alignment: .trailing) { Divider() }
    }

    private func navigation(_ title: String, icon: String, destination: Page,
                            selected: Bool) -> some View {
        Button {
            page = destination
        } label: {
            Label(title, systemImage: icon)
                .font(.system(size: 13, weight: .medium))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .foregroundStyle(selected ? blue : Color.secondary)
                .background(blue.opacity(selected ? 0.09 : 0),
                            in: RoundedRectangle(cornerRadius: 8))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    var landing: some View {
        VStack(alignment: .leading, spacing: 28) {
            VStack(alignment: .leading, spacing: 8) {
                Text(page == .home ? "Phone Studio" : "实用工具")
                    .font(.system(size: 30, weight: .semibold, design: .rounded))
                Text("连接设备，专注调试。")
                    .font(.system(size: 14)).foregroundStyle(.secondary)
            }
            HStack(alignment: .top, spacing: 16) {
                launchCard("设备投屏", subtitle: "触控操作、截图与屏幕录制",
                           icon: "iphone", destination: .mirroring)
                launchCard("设备调试", subtitle: "投屏与实时 Console 日志",
                           icon: "terminal", destination: .debugging)
            }
            Spacer()
        }
        .padding(36)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private func launchCard(_ title: String, subtitle: String, icon: String,
                            destination: Page) -> some View {
        Button { page = destination } label: {
            VStack(alignment: .leading, spacing: 22) {
                Image(systemName: icon)
                    .font(.system(size: 25, weight: .light))
                    .foregroundStyle(blue)
                VStack(alignment: .leading, spacing: 6) {
                    Text(title).font(.system(size: 17, weight: .semibold))
                    Text(subtitle).font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Image(systemName: "arrow.right").foregroundStyle(.secondary)
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 14))
            .overlay { RoundedRectangle(cornerRadius: 14).strokeBorder(.primary.opacity(0.08)) }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
