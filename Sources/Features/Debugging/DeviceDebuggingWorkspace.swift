import AppKit
import SwiftUI

struct DeviceDebuggingWorkspace: View {
    @ObservedObject var phone: Phone
    @StateObject private var console = DeviceConsole()
    @State private var search = ""
    @State private var severity = "全部"
    @State private var follow = true

    private var filtered: [String] {
        console.lines.filter {
            (search.isEmpty || $0.localizedCaseInsensitiveContains(search)) &&
            (severity == "全部" || $0.range(of: " " + severity + " ") != nil)
        }
    }

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Text("设备调试").font(.title2.bold())
                Picker("设备", selection: $phone.deviceID) {
                    Text("选择设备").tag("")
                    ForEach(phone.devices) { Text("Android · " + $0.name).tag($0.id) }
                    ForEach(phone.iosDevices, id: \.self) { Text("iPhone · " + $0).tag($0) }
                    ForEach(phone.harmonyDevices, id: \.self) { Text("鸿蒙 · " + $0).tag($0) }
                }.frame(maxWidth: 360)
                Button("刷新", action: phone.scanDevices)
                Button(phone.mirroring ? "停止调试" : "开始调试") {
                    if phone.mirroring { console.stop(); phone.stop() }
                    else { phone.start(); console.start(phone: phone) }
                }.disabled(!phone.hasSelectedDevice)
                Spacer()
            }
            HSplitView {
                VStack {
                    MirroringPreview(phone: phone, zoom: 1)
                    Text(phone.status).font(.caption).lineLimit(3).textSelection(.enabled)
                }
                .frame(minWidth: 260, idealWidth: 380, maxWidth: .infinity, maxHeight: .infinity)
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Console").font(.headline)
                        Spacer()
                        Button("重连日志") { console.start(phone: phone) }.disabled(!phone.hasSelectedDevice)
                        Button(console.paused ? "继续" : "暂停") { console.paused.toggle() }
                        Button("清空") { console.lines = [] }
                        Button("复制") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(filtered.joined(separator: "\n"), forType: .string)
                        }
                    }
                    HStack {
                        TextField("搜索日志、进程或关键词", text: $search)
                        if !phone.isIOS && !phone.isHarmony {
                            Picker("级别", selection: $severity) {
                                ForEach(["全部", "V", "D", "I", "W", "E", "F"], id: \.self) { Text($0).tag($0) }
                            }.frame(width: 100)
                        }
                        Toggle("跟随", isOn: $follow).toggleStyle(.checkbox)
                    }
                    ConsoleTextView(text: filtered.joined(separator: "\n"), follow: follow)
                    Text(console.paused ? "已暂停 · 暂停期间日志会跳过" : console.message)
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(.leading, 12)
                .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(16)
        .task {
            while !Task.isCancelled {
                phone.scanDevices()
                try? await Task.sleep(for: .seconds(2))
            }
        }
        .onChange(of: phone.deviceID) {
            console.stop()
            phone.stop()
        }
        .onChange(of: phone.mirroring) { if !phone.mirroring { console.stop() } }
        .onDisappear { console.stop(); phone.stop() }
    }
}
