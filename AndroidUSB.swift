import AppKit
import SwiftUI

@MainActor
final class Phone: ObservableObject {
    @Published var status = "插入一台 Android 手机，并在手机上授权 USB 调试。"
    @Published var mirroring = false
    @Published var saving = false
    private var mirror: Process?

    private func run(_ tool: String, _ arguments: [String],
                     completion: @escaping @MainActor (Int32, Data, String) -> Void) {
        let locations = ["/opt/homebrew/bin", "/usr/local/bin"]
        guard let executable = locations.map({ "\($0)/\(tool)" }).first(where: {
            FileManager.default.isExecutableFile(atPath: $0)
        }) else {
            completion(1, Data(), "找不到 \(tool)。请运行 brew install scrcpy android-platform-tools")
            return
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = (locations + [environment["PATH"] ?? "/usr/bin:/bin"]).joined(separator: ":")
        process.environment = environment

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            let output = directory.appendingPathComponent("stdout")
            let errors = directory.appendingPathComponent("stderr")
            try Data().write(to: output)
            try Data().write(to: errors)
            process.standardOutput = try FileHandle(forWritingTo: output)
            process.standardError = try FileHandle(forWritingTo: errors)
            process.terminationHandler = { process in
                let data = (try? Data(contentsOf: output)) ?? Data()
                let diagnostic = (try? String(contentsOf: errors, encoding: .utf8)) ?? ""
                try? FileManager.default.removeItem(at: directory)
                let code = process.terminationStatus
                Task { @MainActor in completion(code, data, diagnostic) }
            }
            try process.run()
            if tool == "scrcpy" { mirror = process }
        } catch {
            try? FileManager.default.removeItem(at: directory)
            completion(1, Data(), error.localizedDescription)
        }
    }

    func start() {
        mirroring = true
        status = "正在启动投屏。请在手机上确认 USB 调试授权。"
        run("scrcpy", ["-d", "--no-audio", "--window-title=Android USB · 投屏"]) { code, data, error in
            self.mirror = nil
            self.mirroring = false
            self.status = code == 0 ? "投屏已关闭。" :
                "投屏已结束。\n" + error + String(decoding: data, as: UTF8.self)
        }
    }

    func stop() {
        mirror?.terminate()
    }

    func screenshot() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Android-\(Int(Date().timeIntervalSince1970)).png"
        panel.allowedContentTypes = [.png]
        guard panel.runModal() == .OK, let destination = panel.url else { return }

        saving = true
        run("adb", ["-d", "exec-out", "screencap", "-p"]) { code, data, error in
            defer { self.saving = false }
            guard code == 0, let bitmap = NSBitmapImageRep(data: data),
                  let png = bitmap.representation(using: .png, properties: [:]) else {
                self.status = "截图失败。请确认只连接了一台已授权的 USB 设备。\n" + error
                return
            }
            do {
                try png.write(to: destination, options: .atomic)
                self.status = "截图已保存到 \(destination.lastPathComponent)"
            } catch {
                self.status = "保存失败。\(error.localizedDescription)"
            }
        }
    }
}

@main
struct AndroidUSB: App {
    @StateObject private var phone = Phone()

    var body: some Scene {
        WindowGroup("Android USB") {
            VStack(alignment: .leading, spacing: 16) {
                Label("Android USB", systemImage: "iphone.gen3")
                    .font(.largeTitle.weight(.semibold))
                Text("在投屏窗口点击、长按或拖动，就能操作手机。")
                    .foregroundStyle(.secondary)
                HStack {
                    Button("打开投屏", action: phone.start).disabled(phone.mirroring)
                        .buttonStyle(.borderedProminent)
                    Button("停止投屏", action: phone.stop).disabled(!phone.mirroring)
                    Button("保存截图…", action: phone.screenshot).disabled(phone.saving)
                }
                Divider()
                ScrollView {
                    Text(phone.status).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(24)
            .frame(width: 480, height: 245)
            .onDisappear { phone.stop() }
        }
        .windowResizability(.contentSize)
    }
}
