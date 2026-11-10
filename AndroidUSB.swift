import AppKit
import SwiftUI

@MainActor
final class Phone: ObservableObject {
    @Published var status = "插入一台 Android 手机，并在手机上授权 USB 调试。"
    @Published var mirroring = false
    @Published var saving = false
    @Published var frame: NSBitmapImageRep?
    @Published var recording = false
    @Published var exportingLogs = false
    struct Device: Identifiable {
        let id: String
        let name: String
    }

    @Published var devices: [Device] = []
    @Published private(set) var harmonyDevices: [String] = []
    @Published var deviceID = ""
    @Published private(set) var osVersions: [String: String] = [:]
    @Published var quality = 20
    private var previewID = UUID()
    private var recorder: Process?
    private var harmonyRecording: (folder: URL, output: URL)?
    private var harmonyFrameCount = 0
    @AppStorage("outputDirectory") var outputDirectory = ""
    private var previewProcess: Process?
    private var scanningDevices = false
    private var loadingVersions: Set<String> = []
    @Published private(set) var harmonyModels: [String: String] = [:]

    var isHarmony: Bool { harmonyDevices.contains(deviceID) }
    var hasSelectedDevice: Bool { isHarmony || devices.contains { $0.id == deviceID } }

    private func run(_ tool: String, _ arguments: [String],
                     completion: @escaping @MainActor (Int32, Data, String) -> Void) {
        var locations = ["/opt/homebrew/bin", "/usr/local/bin"]
        if tool == "hdc" {
            let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/lib/hdc")
            let versions = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
            locations += versions.sorted(by: >).map { root.appendingPathComponent($0).path }
        }
        guard let executable = locations.map({ "\($0)/\(tool)" }).first(where: {
            FileManager.default.isExecutableFile(atPath: $0)
        }) else {
            completion(1, Data(), "找不到 \(tool)。请运行 brew install scrcpy android-platform-tools")
            return
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments.first == "-d" && !deviceID.isEmpty
            ? ["-s", deviceID] + Array(arguments.dropFirst()) : arguments
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
            if tool == "scrcpy" { recorder = process }
        } catch {
            try? FileManager.default.removeItem(at: directory)
            completion(1, Data(), error.localizedDescription)
        }
    }

    func scanDevices() {
        guard !scanningDevices else { return }
        scanningDevices = true
        run("hdc", ["list", "targets", "-v"]) { code, data, _ in
            self.harmonyDevices = code == 0
                ? String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline).compactMap { line in
                    let fields = line.split(whereSeparator: \.isWhitespace)
                    return fields.contains("USB") && fields.contains("Connected") ? fields.first.map(String.init) : nil
                } : []
            self.harmonyDevices.forEach(self.loadOSVersion)
            if self.deviceID.isEmpty && self.devices.isEmpty && !self.recording {
                self.deviceID = self.harmonyDevices.first ?? ""
            }
        }
        run("adb", ["devices", "-l"]) { code, data, error in
            defer { self.scanningDevices = false }
            guard code == 0 else {
                self.status = error
                return
            }
            let lines = String(decoding: data, as: UTF8.self).split(separator: "\n")
            self.devices = lines.compactMap { line in
                let fields = line.split(whereSeparator: \.isWhitespace)
                guard fields.count > 2, fields[1] == "device",
                      fields.contains(where: { $0.hasPrefix("usb:") }) else { return nil }
                let model = fields.first(where: { $0.hasPrefix("model:") })?.dropFirst(6)
                return Device(id: String(fields[0]), name: model.map(String.init) ?? String(fields[0]))
            }
            self.devices.forEach { self.loadOSVersion(for: $0.id) }
            if !self.hasSelectedDevice {
                if self.mirroring {
                    self.stop()
                    self.status = "当前投屏设备已断开。"
                }
                if !self.recording {
                    self.deviceID = self.devices.first?.id ?? self.harmonyDevices.first ?? ""
                }
            }
            if lines.contains(where: { $0.split(whereSeparator: \.isWhitespace).dropFirst().first == "unauthorized" }) {
                self.status = "有手机尚未授权。请解锁手机并确认「允许 USB 调试」。"
            } else if self.devices.isEmpty && self.harmonyDevices.isEmpty && !self.recording {
                self.status = "未找到已授权的 USB 设备。请检查数据线和 USB 调试。"
            }
        }
    }

    func loadOSVersion(for id: String) {
        guard !id.isEmpty, osVersions[id] == nil,
              loadingVersions.insert(id).inserted else { return }
        let harmony = harmonyDevices.contains(id)
        let arguments = harmony
            ? ["-t", id, "shell", "param get const.product.os.dist.version; param get const.product.model"]
            : ["-s", id, "shell", "getprop", "ro.build.version.release"]
        run(harmony ? "hdc" : "adb", arguments) { code, data, _ in
            self.loadingVersions.remove(id)
            let values = String(decoding: data, as: UTF8.self)
                .split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            if code == 0, let version = values.first, version.first?.isNumber == true {
                self.osVersions[id] = version
                if harmony, values.count > 1, !values[1].isEmpty { self.harmonyModels[id] = values[1] }
            }
        }
    }

    func command(_ arguments: [String]) {
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
        panel.allowedContentTypes = (isHarmony ? ["hap", "hsp"] : ["apk"]).compactMap { .init(filenameExtension: $0) }
        guard panel.runModal() == .OK, let file = panel.url else { return }
        command(["install", "-r", file.path])
    }

    func push() {
        let panel = NSOpenPanel()
        guard panel.runModal() == .OK, let file = panel.url else { return }
        if isHarmony {
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
        command(["uninstall", package])
    }

    private func ask(_ title: String, prompt: String, initial: String = "") -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = prompt
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.stringValue = initial
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        alert.addButton(withTitle: "确认")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func start() {
        if isHarmony {
            previewID = UUID()
            mirroring = true
            status = "正在连接鸿蒙手机…"
            refreshHarmony(previewID, device: deviceID)
            return
        }
        let paths = ["/opt/homebrew/bin/adb", "/usr/local/bin/adb"]
        guard let adb = paths.first(where: FileManager.default.isExecutableFile(atPath:)) else {
            status = "找不到 adb。请安装 android-platform-tools。"
            return
        }
        let id = UUID()
        previewID = id
        let process = Process()
        let output = Pipe()
        let reader = output.fileHandleForReading
        process.executableURL = URL(fileURLWithPath: adb)
        let interval = quality == 20 ? "0.02" : "0.25"
        process.arguments = ["-s", deviceID, "exec-out",
                             "while screencap -p; do sleep \(interval); done"]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            status = "无法启动预览。\n" + error.localizedDescription
            return
        }
        previewProcess = process
        mirroring = true
        status = "正在连接 Android 手机…"
        Task.detached { [weak self] in
            defer { try? reader.close() }
            while let data = try? Self.readFrame(from: reader) {
                guard await self?.showFrame(data, id: id) == true else { return }
            }
            await self?.previewEnded(id)
        }
    }

    private func captureHarmony(_ id: String, jpeg: Bool = false,
                                completion: @escaping @MainActor (Int32, Data, String) -> Void) {
        let path = "/data/local/tmp/phone-studio-\(UUID().uuidString).\(jpeg ? "jpeg" : "png")"
        let capture = jpeg ? "snapshot_display -t jpeg -f \(path)" : "uitest screenCap -p \(path)"
        let command = "trap 'rm -f \(path)' EXIT; \(capture) >/dev/null && base64 \(path)"
        run("hdc", ["-t", id, "shell", command]) { code, output, error in
            let image = Data(base64Encoded: output, options: .ignoreUnknownCharacters)
            completion(code, image ?? Data(), error)
        }
    }

    private func refreshHarmony(_ session: UUID, device: String, jpeg: Bool = true) {
        captureHarmony(device, jpeg: jpeg) { code, data, _ in
            guard self.previewID == session else { return }
            guard code == 0, let image = NSBitmapImageRep(data: data) else {
                if jpeg {
                    self.refreshHarmony(session, device: device, jpeg: false)
                } else {
                    self.previewEnded(session)
                }
                return
            }
            if self.frame == nil { self.status = "已连接。点击或拖动中间画面来操作手机。" }
            self.frame = image
            Task {
                try? await Task.sleep(for: .milliseconds(self.quality))
                guard self.previewID == session else { return }
                self.refreshHarmony(session, device: device, jpeg: jpeg)
            }
        }
    }

    nonisolated private static func readFrame(from reader: FileHandle) throws -> Data? {
        func read(_ count: Int) throws -> Data? {
            var bytes = Data()
            while bytes.count < count {
                guard let part = try reader.read(upToCount: count - bytes.count),
                      !part.isEmpty else { return nil }
                bytes.append(part)
            }
            return bytes
        }

        guard var png = try read(8),
              png == Data([137, 80, 78, 71, 13, 10, 26, 10]) else { return nil }
        // PNG chunks are length, four-byte type, payload, then CRC.
        while let header = try read(8) {
            let length = header.prefix(4).reduce(0) { ($0 << 8) | Int($1) }
            guard png.count + length + 12 <= 32 * 1024 * 1024,
                  let payload = try read(length + 4) else { return nil }
            png.append(header)
            png.append(payload)
            if header.suffix(4).elementsEqual([73, 69, 78, 68]) { return png }
        }
        return nil
    }

    private func showFrame(_ data: Data, id: UUID) -> Bool {
        guard previewID == id else { return false }
        if let image = NSBitmapImageRep(data: data) {
            if frame == nil { status = "已连接。点击或拖动中间画面来操作手机。" }
            frame = image
        }
        return true
    }

    private func previewEnded(_ id: UUID) {
        guard previewID == id else { return }
        stop()
        status = "投屏连接中断。请检查 USB 数据线和调试授权。"
    }

    func stop() {
        previewID = UUID()
        if let process = previewProcess, process.isRunning { process.terminate() }
        previewProcess = nil
        mirroring = false
        frame = nil
    }

    func input(_ drag: DragGesture.Value, size: CGSize, image: NSBitmapImageRep) {
        func point(_ p: CGPoint) -> [String] {
            let x = Int(max(0, min(size.width, p.x)) / size.width * CGFloat(image.pixelsWide - 1))
            let y = Int(max(0, min(size.height, p.y)) / size.height * CGFloat(image.pixelsHigh - 1))
            return [String(x), String(y)]
        }
        let start = point(drag.startLocation)
        let end = point(drag.location)
        let moved = hypot(drag.translation.width, drag.translation.height) >= 5
        if isHarmony {
            let gesture = moved ? ["swipe"] + start + end + ["2500"] : ["click"] + start
            run("hdc", ["-t", deviceID, "shell", "uitest", "uiInput"] + gesture) { code, _, error in
                if code != 0 { self.status = "鸿蒙触控失败。\n" + error }
            }
            return
        }
        let command = moved ? ["swipe"] + start + end + ["150"] : ["tap"] + start
        run("adb", ["-d", "shell", "input"] + command) { code, _, error in
            if code != 0 { self.status = "触控失败。\n" + error }
        }
    }

    private var preferredDirectory: URL? {
        if !outputDirectory.isEmpty { return URL(fileURLWithPath: outputDirectory, isDirectory: true) }
        return FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
    }

    func chooseOutputDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.directoryURL = preferredDirectory
        panel.prompt = "设为保存目录"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        outputDirectory = url.path
        status = "默认保存目录：\(url.path)"
    }

    func startRecording() {
        let panel = NSSavePanel()
        panel.directoryURL = preferredDirectory
        panel.nameFieldStringValue = "\(isHarmony ? "Harmony" : "Android")-\(Int(Date().timeIntervalSince1970)).mp4"
        panel.allowedContentTypes = [.mpeg4Movie]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if isHarmony {
            startHarmonyRecording(to: url)
            return
        }
        recording = true
        status = "正在录屏。点击「停止录屏」保存 MP4。"
        run("scrcpy", ["-d", "--no-playback", "--no-control", "--no-audio",
                       "--record=\(url.path)"]) { code, _, error in
            self.recording = false
            self.recorder = nil
            self.status = code == 0 ? "录屏已保存到 \(url.lastPathComponent)" :
                "录屏结束异常，请检查输出文件。\n" + error
        }
    }

    private func startHarmonyRecording(to output: URL) {
        guard ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"]
            .contains(where: FileManager.default.isExecutableFile(atPath:)) else {
            status = "鸿蒙录屏需要 FFmpeg。请运行 brew install ffmpeg。"
            return
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
            harmonyRecording = (folder, output)
            harmonyFrameCount = 0
            recording = true
            status = "正在录制鸿蒙画面。点击「停止录制」保存无声 MP4。"
            recordHarmonyFrame(deviceID, folder: folder)
        } catch {
            status = error.localizedDescription
        }
    }

    private func recordHarmonyFrame(_ id: String, folder: URL) {
        captureHarmony(id, jpeg: true) { code, data, _ in
            guard self.harmonyRecording?.folder == folder else { return }
            guard code == 0, NSBitmapImageRep(data: data) != nil else {
                self.stopRecording()
                return
            }
            do {
                let name = String(format: "%06d.jpeg", self.harmonyFrameCount)
                try data.write(to: folder.appendingPathComponent(name), options: .atomic)
                self.harmonyFrameCount += 1
            } catch {
                self.stopRecording()
                return
            }
            Task {
                try? await Task.sleep(for: .milliseconds(80))
                guard self.harmonyRecording?.folder == folder else { return }
                self.recordHarmonyFrame(id, folder: folder)
            }
        }
    }

    func stopRecording() {
        guard let session = harmonyRecording else {
            if let recorder, recorder.isRunning { recorder.interrupt() }
            return
        }
        harmonyRecording = nil
        guard harmonyFrameCount > 0 else {
            try? FileManager.default.removeItem(at: session.folder)
            recording = false
            status = "鸿蒙录屏未取得画面。"
            return
        }
        status = "正在生成鸿蒙录屏…"
        let video = session.folder.appendingPathComponent("recording.mp4")
        run("ffmpeg", ["-v", "error", "-framerate", "1", "-i",
                       session.folder.appendingPathComponent("%06d.jpeg").path,
                       "-vf", "scale=720:1280:force_original_aspect_ratio=decrease,pad=720:1280:(ow-iw)/2:(oh-ih)/2",
                       "-c:v", "libx264", "-pix_fmt", "yuv420p", video.path]) { code, _, error in
            defer {
                self.recording = false
                try? FileManager.default.removeItem(at: session.folder)
            }
            guard code == 0 else {
                self.status = "鸿蒙录屏生成失败。\n" + error
                return
            }
            do {
                if FileManager.default.fileExists(atPath: session.output.path) {
                    _ = try FileManager.default.replaceItemAt(session.output, withItemAt: video)
                } else {
                    try FileManager.default.moveItem(at: video, to: session.output)
                }
                self.status = "录屏已保存到 \(session.output.lastPathComponent)"
            } catch {
                self.status = "保存录屏失败。\n" + error.localizedDescription
            }
        }
    }

    func exportLogs() {
        let panel = NSSavePanel()
        let harmony = isHarmony
        let logName = harmony ? "HiLog" : "Logcat"
        panel.directoryURL = preferredDirectory
        panel.nameFieldStringValue = "\(logName)-\(Int(Date().timeIntervalSince1970)).txt"
        panel.allowedContentTypes = [.plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        exportingLogs = true
        let arguments = harmony ? ["-t", deviceID, "shell", "hilog", "-x"] :
            ["-d", "logcat", "-b", "main", "-b", "system", "-b", "crash", "-d", "-v", "threadtime"]
        run(harmony ? "hdc" : "adb", arguments) { code, data, error in
            defer { self.exportingLogs = false }
            guard code == 0 else {
                self.status = "导出日志失败。\n" + error
                return
            }
            do {
                try data.write(to: url, options: .atomic)
                self.status = "\(logName) 已保存到 \(url.lastPathComponent)"
            } catch {
                self.status = "保存日志失败。\(error.localizedDescription)"
            }
        }
    }

    func screenshot() {
        let panel = NSSavePanel()
        panel.directoryURL = preferredDirectory
        panel.nameFieldStringValue = "\(isHarmony ? "Harmony" : "Android")-\(Int(Date().timeIntervalSince1970)).png"
        panel.allowedContentTypes = [.png]
        guard panel.runModal() == .OK, let destination = panel.url else { return }

        saving = true
        let save: @MainActor (Int32, Data, String) -> Void = { code, data, error in
            defer { self.saving = false }
            guard code == 0, NSBitmapImageRep(data: data) != nil else {
                self.status = "截图失败。请检查所选设备的 USB 调试连接。\n" + error
                return
            }
            do {
                try data.write(to: destination, options: .atomic)
                self.status = "截图已保存到 \(destination.lastPathComponent)"
            } catch {
                self.status = "保存失败。\(error.localizedDescription)"
            }
        }
        if isHarmony {
            captureHarmony(deviceID, completion: save)
        } else {
            run("adb", ["-d", "exec-out", "screencap", "-p"], completion: save)
        }
    }
}

@main
struct AndroidUSB: App {
    @StateObject private var phone = Phone()

    @State private var page: Page = .home
    @State private var previewExpanded = false
    @State private var directoryCollapsed = false
    @State private var toolsCollapsed = false
    @State private var zoom = 1.0
    @State private var deviceMenuOpen = false
    @State private var shellCommand = ""
    private let blue = Color(red: 0, green: 0.49, blue: 1)
    private let canvas = Color(red: 0.94, green: 0.95, blue: 0.96)

    private enum Page {
        case home, utilities, mirroring
    }

    var body: some Scene {
        WindowGroup("Phone USB Studio") {
            HStack(spacing: 0) {
                if !previewExpanded {
                    if directoryCollapsed {
                        collapsedRail("展开导航", icon: "sidebar.left") {
                            directoryCollapsed = false
                        }
                    } else {
                        directory
                    }
                }
                switch page {
                case .home, .utilities:
                    landing
                case .mirroring:
                    workspace
                }
            }
            .frame(minWidth: 850, minHeight: 570)
            .onDisappear {
                phone.stop()
                phone.stopRecording()
            }
        }
        .defaultSize(width: 1350, height: 820)
    }

    private var directory: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("PHONE STUDIO")
                    .font(.system(size: 15, weight: .bold, design: .monospaced))
                    .tracking(0.6)
                    .foregroundStyle(.white.opacity(0.75))
                Spacer(minLength: 4)
                sidebarButton("收起导航", icon: "sidebar.left") {
                    directoryCollapsed = true
                }
            }
            Text("设备工作台").font(.system(size: 18, weight: .semibold))
                .padding(.bottom, 16)

            navigation("首页", icon: "house", destination: .home, selected: page == .home)
            navigation("实用工具", icon: "wrench.and.screwdriver",
                       destination: .utilities, selected: page != .home)
            Spacer()
        }
        .foregroundStyle(.white)
        .padding(16)
        .frame(width: 200)
        .background(LinearGradient(colors: [blue, Color(red: 0.36, green: 0.67, blue: 0.96)], startPoint: .top, endPoint: .bottom))
    }

    private func collapsedRail(_ title: String, icon: String,
                               action: @escaping () -> Void) -> some View {
        VStack {
            sidebarButton(title, icon: icon, action: action)
            Spacer(minLength: 0)
        }
        .padding(.top, 16)
        .frame(width: 42)
        .background(.regularMaterial)
    }

    private func sidebarButton(_ title: String, icon: String,
                               action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(title)
        .accessibilityLabel(title)
    }

    private func navigation(_ title: String, icon: String, destination: Page,
                            selected: Bool) -> some View {
        Button {
            page = destination
        } label: {
            Label(title, systemImage: icon)
                .font(.callout.weight(.medium))
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

    private var landing: some View {
        VStack(alignment: .leading, spacing: 18) {
            let home = page == .home
            toolCard(home ? "首页" : "工具目录") {
                Text(home ? "Phone USB Studio" : "实用工具")
                    .font(.largeTitle.weight(.semibold))
                Text(home ? "通过 USB 连接 Android 或鸿蒙手机，在 Mac 上查看和操作设备。"
                          : "选择一个工具开始操作已连接的手机。")
                    .foregroundStyle(.secondary)
            }
            Button {
                page = home ? .utilities : .mirroring
            } label: {
                toolCard(home ? "实用工具" : "设备投屏") {
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

    private var workspace: some View {
        VStack(spacing: 10) {
            HStack(spacing: 14) {
                Button { page = .utilities; previewExpanded = false } label: {
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
                    preview
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(.white, in: RoundedRectangle(cornerRadius: 11))
                        .clipShape(RoundedRectangle(cornerRadius: 11))
                    if !previewExpanded {
                        if toolsCollapsed {
                            collapsedRail("展开功能", icon: "sidebar.right") { toolsCollapsed = false }
                        } else {
                            tools.frame(width: max(268, geometry.size.width * 0.40))
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

    private var toolbar: some View {
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
        let ids = phone.devices.map(\.id) + phone.harmonyDevices
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
        let model = phone.harmonyModels[id] ?? phone.devices.first(where: { $0.id == id })?.name ?? "Harmony"
        return "\(masked)（\(model)）"
    }

    private func deviceDetails(_ id: String) -> String {
        let harmony = phone.harmonyDevices.contains(id)
        let platform = harmony ? "Harmony" : "Android"
        let system = harmony ? "HarmonyOS" : "Android"
        let os = phone.osVersions[id].map { "\(system) \($0)" } ?? system
        return "\(platform) · \(os)"
    }

    private var tools: some View {
        ScrollView {
            VStack(spacing: 9) {
                toolCard("按键区") {
                    HStack(spacing: 6) {
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
                        Spacer(minLength: 0)
                        sidebarButton("收起功能", icon: "sidebar.right") { toolsCollapsed = true }
                    }
                }
                toolCard("设备/应用信息") {
                    HStack(spacing: 6) {
                        tile("安装应用", "square.and.arrow.down", phone.install)
                        tile("卸载应用", "trash", phone.uninstall)
                        tile("应用信息", "square.grid.2x2") {
                            phone.command(phone.isHarmony ? ["shell", "bm", "dump", "-a"] :
                                          ["shell", "pm", "list", "packages", "-3"])
                        }
                    }
                }
                toolCard("文件信息") {
                    HStack(spacing: 6) {
                        tile("文件推送", "square.and.arrow.up", phone.push)
                        tile("文件获取", "arrow.down.circle", phone.pull)
                        tile("日志获取", "doc.text", phone.exportLogs).disabled(phone.exportingLogs)
                    }
                }
                toolCard("快捷操作") {
                    HStack(spacing: 6) {
                        tile("截屏", "camera.viewfinder", phone.screenshot).disabled(phone.saving)
                        tile(phone.recording ? "停止录制" : "屏幕录制",
                             phone.recording ? "stop.circle" : "video") {
                            if phone.recording { phone.stopRecording() } else { phone.startRecording() }
                        }

                    }
                }
                toolCard("保存位置") {
                    HStack {
                        Text(phone.outputDirectory.isEmpty ? "下载文件夹" : phone.outputDirectory)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Button("更改目录…", action: phone.chooseOutputDirectory)
                    }
                }
                toolCard("自定义指令") {
                    HStack {
                        Text(phone.isHarmony ? "hdc shell" : "adb shell")
                        TextField("输入设备 shell 命令", text: $shellCommand)
                        Button("发送") { phone.command(["shell", shellCommand]) }
                            .buttonStyle(.borderedProminent)
                            .tint(blue)
                            .disabled(phone.deviceID.isEmpty || shellCommand.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
                toolCard("执行日志") {
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

    private func toolCard<Content: View>(_ title: String,
                                         @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 15, weight: .semibold))
            content()
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background, in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10).strokeBorder(.primary.opacity(0.07))
                .allowsHitTesting(false)
        }
    }

    private var preview: some View {
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
                                 "在手机的「开发者选项」中开启 USB 调试，\n连接并授权后，点击上方的「开始投屏」。")
                                .foregroundStyle(Color(red: 0.50, green: 0.53, blue: 0.58))
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
    }
}
