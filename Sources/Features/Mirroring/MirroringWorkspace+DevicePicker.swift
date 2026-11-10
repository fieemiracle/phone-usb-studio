import AppKit
import SwiftUI

extension MirroringWorkspace {
    var toolbar: some View {
        HStack(spacing: 10) {
            devicePicker
            sidebarButton("刷新设备", icon: "arrow.clockwise", action: phone.scanDevices)
            Button(phone.mirroring ? "停止投屏" : "开始投屏") {
                if phone.mirroring { phone.stop() } else { phone.start() }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .tint(blue)
            .disabled(!phone.hasSelectedDevice && !phone.mirroring)
            Picker("刷新频率", selection: $phone.quality) {
                Text("流畅").tag(20)
                Text("省资源").tag(250)
            }
            .labelsHidden()
            .frame(width: 90)
            .disabled(phone.isIOS)
            .onChange(of: phone.quality) {
                if phone.mirroring {
                    phone.stop()
                    phone.start()
                }
            }
            Text("缩放比")
            Picker("缩放比", selection: $zoom) {
                Text("0.75").tag(0.75)
                Text("1.0").tag(1.0)
                Text("1.25").tag(1.25)
            }
            .labelsHidden()
            .frame(width: 74)
            Spacer(minLength: 0)
        }
        .frame(height: 40)
    }

    private var devicePicker: some View {
        let ids = phone.devices.map(\.id) + phone.harmonyDevices + phone.iosDevices
        return Button {
            deviceMenuOpen.toggle()
        } label: {
            HStack {
                Text(phone.hasSelectedDevice ? deviceTitle(phone.deviceID) : "选择设备")
                    .lineLimit(1)
                    .foregroundStyle(phone.hasSelectedDevice ? Color.primary : .secondary)
                Spacer(minLength: 6)
                Image(systemName: deviceMenuOpen ? "chevron.up" : "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
            }
            .padding(.horizontal, 10)
            .frame(height: 34)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(maxWidth: 400)
        .background(.white, in: RoundedRectangle(cornerRadius: 5))
        .overlay {
            RoundedRectangle(cornerRadius: 5)
                .strokeBorder(deviceMenuOpen ? blue : .black.opacity(0.15))
                .allowsHitTesting(false)
        }
        .disabled(ids.isEmpty || phone.recording)
        .accessibilityLabel("选择设备")
        .help(phone.hasSelectedDevice ? deviceDetails(phone.deviceID) : "选择设备")
        .popover(isPresented: $deviceMenuOpen, arrowEdge: .bottom) {
            ScrollView {
                VStack(spacing: 5) {
                    ForEach(ids, id: \.self) { id in
                        Button {
                            deviceMenuOpen = false
                            guard id != phone.deviceID, !phone.recording else { return }
                            let resume = phone.mirroring
                            if resume { phone.stop() }
                            phone.deviceID = id
                            if resume { phone.start() }
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(deviceTitle(id)).font(.system(size: 13, weight: .semibold))
                                        .foregroundStyle(id == phone.deviceID ? blue : Color.primary)
                                    Text(deviceDetails(id)).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if id == phone.deviceID {
                                    Image(systemName: "checkmark").foregroundStyle(blue)
                                }
                            }
                            .padding(9)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(.white, in: RoundedRectangle(cornerRadius: 5))
                            .overlay {
                                RoundedRectangle(cornerRadius: 5).strokeBorder(.black.opacity(0.09))
                                    .allowsHitTesting(false)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(8)
            }
            .frame(width: 380, height: min(260, CGFloat(max(1, ids.count) * 56 + 16)))
            .background(canvas)
        }
    }

    private func deviceTitle(_ id: String) -> String {
        let masked = id.count >= 8 ? "\(id.prefix(id.count == 8 ? 2 : 4))****\(id.suffix(id.count == 8 ? 2 : 4))" : id
        let model = phone.iosModels[id] ?? phone.harmonyModels[id] ?? phone.devices.first(where: { $0.id == id })?.name ?? "Harmony"
        return "\(masked)（\(model)）"
    }

    private func deviceDetails(_ id: String) -> String {
        let harmony = phone.harmonyDevices.contains(id)
        let ios = phone.iosDevices.contains(id) || (phone.isIOS && phone.deviceID == id)
        let platform = ios ? "iPhone" : (harmony ? "Harmony" : "Android")
        let system = ios ? "iOS" : (harmony ? "HarmonyOS" : "Android")
        let os = phone.osVersions[id].map { "\(system) \($0)" } ?? system
        return "\(platform) · \(os)"
    }
}
