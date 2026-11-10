import AppKit
import SwiftUI

struct MirroringWorkspace: View {
    @ObservedObject var phone: Phone
    @Binding var previewExpanded: Bool
    @Binding var toolsCollapsed: Bool
    @Binding var zoom: Double
    @Binding var deviceMenuOpen: Bool
    @Binding var shellCommand: String
    let onBack: () -> Void

    let blue = Color(red: 0, green: 0.49, blue: 1)
    let canvas = Color(red: 0.94, green: 0.95, blue: 0.96)

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 14) {
                Button(action: onBack) {
                    Label("返回", systemImage: "arrow.left")
                }
                .buttonStyle(.plain)
                Divider().frame(height: 14)
                Text("设备投屏").font(.system(size: 17, weight: .semibold))
                Spacer()
                if phone.recording { Label("录制中", systemImage: "record.circle.fill").foregroundStyle(.red) }
                sidebarButton(previewExpanded ? "退出放大" : "放大预览",
                              icon: "arrow.up.left.and.arrow.down.right") {
                    previewExpanded.toggle()
                }
            }
            .padding(.horizontal, 16)
            .frame(height: 40)
            .background(.white, in: RoundedRectangle(cornerRadius: 11))
            toolbar
            GeometryReader { geometry in
                HStack(spacing: 12) {
                    MirroringPreview(phone: phone, zoom: zoom)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(.white, in: RoundedRectangle(cornerRadius: 11))
                        .clipShape(RoundedRectangle(cornerRadius: 11))
                    if !previewExpanded {
                        SidebarPanel(width: max(268, geometry.size.width * 0.40),
                                     leading: false, collapsed: $toolsCollapsed) {
                            tools
                        }
                    }
                }
            }
        }
        .font(.system(size: 13))
        .foregroundStyle(Color(red: 0.16, green: 0.17, blue: 0.19))
        .padding([.horizontal, .bottom], 16)
        .background(canvas)
        .environment(\.colorScheme, .light)
        .task {
            while !Task.isCancelled {
                phone.scanDevices()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }
}
