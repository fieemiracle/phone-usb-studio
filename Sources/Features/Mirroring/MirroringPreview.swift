import AppKit
import SwiftUI

struct MirroringPreview: View {
    @ObservedObject var phone: Phone
    let zoom: Double

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                if let frame = phone.frame, let cgImage = frame.cgImage {
                    let width = CGFloat(frame.pixelsWide)
                    let height = CGFloat(frame.pixelsHigh)
                    let scale = min((geometry.size.width - 24) / width,
                                    (geometry.size.height - 16) / height) * zoom
                    let size = CGSize(width: width * scale, height: height * scale)
                    Image(decorative: cgImage, scale: 1)
                        .resizable()
                        .frame(width: size.width, height: size.height)
                        .overlay {
                            Rectangle().strokeBorder(.black.opacity(0.12), lineWidth: 1)
                                .allowsHitTesting(false)
                        }
                        .shadow(color: .black.opacity(0.16), radius: 14, y: 7)
                        .contentShape(Rectangle())
                        .gesture(DragGesture(minimumDistance: 0).onEnded {
                            phone.input($0, size: size, image: frame)
                        })
                } else {
                    VStack(spacing: 11) {
                        Text(phone.mirroring ? "正在读取手机画面…" :
                             phone.isIOS ? "iPhone 已连接。解锁手机后，点击上方的「开始投屏」。" :
                             "在手机的「开发者选项」中开启 USB 调试，\n连接并授权后，点击上方的「开始投屏」。")
                            .foregroundStyle(Color(red: 0.50, green: 0.53, blue: 0.58))
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
