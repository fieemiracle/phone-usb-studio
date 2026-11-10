import AppKit
import AVFoundation
import CoreMediaIO
import CoreImage
import SwiftUI

private final class IOSScreenCapture: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let queue = DispatchQueue(label: "local.android-usb.iphone-capture")
    private let session = AVCaptureSession()
    private let context = CIContext()
    private let onFrame: @Sendable (CGImage) -> Void
    private var lastFrame = 0.0
    private var stopped = false

    init(onFrame: @escaping @Sendable (CGImage) -> Void) {
        self.onFrame = onFrame
    }

    func start(deviceID: String, failure: @escaping @Sendable (String) -> Void) {
        queue.async {
            var address = CMIOObjectPropertyAddress(
                mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyAllowScreenCaptureDevices),
                mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
                mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
            var enabled: UInt32 = 1
            let status = CMIOObjectSetPropertyData(CMIOObjectID(kCMIOObjectSystemObject),
                                                   &address, 0, nil, 4, &enabled)
            guard status == 0 else {
                failure("无法启用 iPhone USB 屏幕源（\(status)）。")
                return
            }
            self.discover(deviceID: deviceID, attempts: 8, failure: failure)
        }
    }

    private func discover(deviceID: String, attempts: Int,
                          failure: @escaping @Sendable (String) -> Void) {
        guard !stopped else { return }
        let sources = AVCaptureDevice.DiscoverySession(deviceTypes: [.external],
                                                       mediaType: .muxed, position: .unspecified)
        guard let device = sources.devices.first(where: { $0.uniqueID.caseInsensitiveCompare(deviceID) == .orderedSame }) else {
            if attempts > 1 {
                queue.asyncAfter(deadline: .now() + .milliseconds(400)) {
                    self.discover(deviceID: deviceID, attempts: attempts - 1, failure: failure)
                }
            } else {
                failure("没有找到这台 iPhone 的屏幕源。请解锁 iPhone 并确认 USB 信任。")
            }
            return
        }
        do {
            let input = try AVCaptureDeviceInput(device: device)
            let output = AVCaptureVideoDataOutput()
            output.alwaysDiscardsLateVideoFrames = true
            output.setSampleBufferDelegate(self, queue: queue)
            guard session.canAddInput(input) else {
                failure("无法打开 iPhone 屏幕输入。")
                return
            }
            session.addInput(input)
            guard session.canAddOutput(output) else {
                failure("无法读取 iPhone 屏幕帧。")
                return
            }
            session.addOutput(output)
            session.startRunning()
        } catch {
            failure(error.localizedDescription)
        }
    }

    func stop() {
        queue.async {
            self.stopped = true
            if self.session.isRunning { self.session.stopRunning() }
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        let now = ProcessInfo.processInfo.systemUptime
        guard !stopped, now - lastFrame >= 1.0 / 20,
              let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        lastFrame = now
        let image = CIImage(cvPixelBuffer: buffer)
        if let frame = context.createCGImage(image, from: image.extent) { onFrame(frame) }
    }
}

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
    @Published private(set) var iosDevices: [String] = []
    @Published private(set) var iosModels: [String: String] = [:]
    @Published var deviceID = "" {
        didSet { if deviceID != oldValue { stopIOSControl() } }
    }
    @Published private(set) var osVersions: [String: String] = [:]
    @Published var quality = 20
    private var previewID = UUID()
    private var recorder: Process?
    private var frameRecording: (folder: URL, output: URL, fps: Int)?
    private var recordedFrameCount = 0
    @AppStorage("outputDirectory") var outputDirectory = ""
    private var previewProcess: Process?
    private var iosCapture: IOSScreenCapture?
    private var wdaProxy: Process?
    private var wdaPort = 0
    private var wdaSession: String?
    private var wdaBusy = false
    private var iosPreviewDeviceID: String?
    private var scanningDevices = false
    private var loadingVersions: Set<String> = []
    @Published private(set) var harmonyModels: [String: String] = [:]

    var isHarmony: Bool { harmonyDevices.contains(deviceID) }
    var isIOS: Bool { iosPreviewDeviceID == deviceID || iosDevices.contains(deviceID) }
    var hasSelectedDevice: Bool { isIOS || isHarmony || devices.contains { $0.id == deviceID } }

    private func run(_ tool: String, _ arguments: [String], timeout: Duration? = nil,
                     completion: @escaping @MainActor (Int32, Data, String) -> Void) {
        var locations = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"]
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
            if let timeout {
                Task {
                    try? await Task.sleep(for: timeout)
                    if process.isRunning { process.interrupt() }
                }
            }
        } catch {
            try? FileManager.default.removeItem(at: directory)
            completion(1, Data(), error.localizedDescription)
        }
    }

    func scanDevices() {
        guard !scanningDevices else { return }
        scanningDevices = true
        run("idevice_id", ["-l"]) { code, data, _ in
            self.iosDevices = code == 0 ? String(decoding: data, as: UTF8.self)
                .split(whereSeparator: \.isWhitespace).map(String.init) : []
            self.iosDevices.forEach(self.loadOSVersion)
            if self.deviceID.isEmpty && self.devices.isEmpty && self.harmonyDevices.isEmpty && !self.recording {
                self.deviceID = self.iosDevices.first ?? ""
            }
        }
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
                    self.deviceID = self.devices.first?.id ?? self.harmonyDevices.first ?? self.iosDevices.first ?? ""
                }
            }
            if lines.contains(where: { $0.split(whereSeparator: \.isWhitespace).dropFirst().first == "unauthorized" }) {
                self.status = "有手机尚未授权。请解锁手机并确认「允许 USB 调试」。"
            } else if self.devices.isEmpty && self.harmonyDevices.isEmpty && self.iosDevices.isEmpty && !self.recording {
                self.status = "未找到已授权的 USB 设备。请检查数据线和 USB 调试。"
            }
        }
    }

    func loadOSVersion(for id: String) {
        guard !id.isEmpty, osVersions[id] == nil,
              loadingVersions.insert(id).inserted else { return }
        if iosDevices.contains(id) {
            run("ideviceinfo", ["-u", id, "-x"]) { code, data, _ in
                self.loadingVersions.remove(id)
                guard code == 0,
                      let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
                else { return }
                self.osVersions[id] = info["ProductVersion"] as? String
                if let model = info["ProductType"] as? String {
                    self.iosModels[id] = model == "iPhone11,2" ? "iPhone XS" : model
                }
            }
            return
        }
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
        guard hasSelectedDevice else { return }
        if isIOS {
            startIOSPreview()
            return
        }
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

    private func startIOSPreview() {
        let id = UUID()
        let target = deviceID
        iosPreviewDeviceID = target
        previewID = id
        mirroring = true
        status = "正在打开 iPhone USB 屏幕源…"
        Task {
            let authorized = await AVCaptureDevice.requestAccess(for: .video)
            guard previewID == id else { return }
            guard authorized else {
                stop()
                status = "请在 macOS「隐私与安全性 → 摄像头」中允许本应用访问 iPhone USB 屏幕源。"
                return
            }
            let capture = IOSScreenCapture { [weak self] image in
                Task { @MainActor in
                    guard let self, self.previewID == id else { return }
                    if self.frame == nil { self.status = "iPhone USB 投屏已连接。" }
                    self.frame = NSBitmapImageRep(cgImage: image)
                }
            }
            iosCapture = capture
            capture.start(deviceID: target) { [weak self] error in
                Task { @MainActor in
                    guard let self, self.previewID == id else { return }
                    self.stop()
                    self.status = error
                }
            }
            try? await Task.sleep(for: .seconds(8))
            guard previewID == id, frame == nil else { return }
            stop()
            status = "检测到 iPhone，但没有收到画面。请保持手机解锁，重新插线后再试。"
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
        if isIOS && frameRecording != nil { stopRecording() }
        stopIOSControl()
        iosCapture?.stop()
        iosCapture = nil
        iosPreviewDeviceID = nil
        if let process = previewProcess, process.isRunning { process.terminate() }
        previewProcess = nil
        mirroring = false
        frame = nil
    }

    private func wdaRequest(_ path: String, body: [String: Any]? = nil) async throws -> [String: Any] {
        guard let url = URL(string: "http://127.0.0.1:\(wdaPort)" + path) else {
            throw URLError(.badURL)
        }
        var request = URLRequest(url: url, timeoutInterval: 5)
        if let body {
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return payload
    }

    private func performIOSControl(_ action: @escaping @MainActor (String) async throws -> Void) {
        guard isIOS, !wdaBusy else { return }
        let target = deviceID
        wdaBusy = true
        Task {
            defer { wdaBusy = false }
            do {
                if wdaProxy?.isRunning != true {
                    guard let executable = ["/opt/homebrew/bin/iproxy", "/usr/local/bin/iproxy"]
                        .first(where: FileManager.default.isExecutableFile(atPath:)) else {
                        status = "找不到 iproxy。请安装 libusbmuxd。"
                        return
                    }
                    let process = Process()
                    wdaPort = Int.random(in: 49152...65535)
                    process.executableURL = URL(fileURLWithPath: executable)
                    process.arguments = ["-l", "-s", "127.0.0.1", "-u", target, "\(wdaPort):8100"]
                    process.standardOutput = FileHandle.nullDevice
                    process.standardError = FileHandle.nullDevice
                    try process.run()
                    wdaProxy = process
                    try await Task.sleep(for: .milliseconds(250))
                    guard process.isRunning else { throw URLError(.cannotConnectToHost) }
                }
                guard deviceID == target, wdaProxy?.isRunning == true else { return }
                if wdaSession == nil {
                    let reply = try await wdaRequest("/session", body: [
                        "capabilities": ["alwaysMatch": ["shouldTerminateApp": false], "firstMatch": [[:]]]
                    ])
                    let value = reply["value"] as? [String: Any]
                    wdaSession = (value?["sessionId"] as? String) ?? (reply["sessionId"] as? String)
                }
                guard deviceID == target, let id = wdaSession,
                      id.range(of: #"^[A-Za-z0-9-]+$"#, options: .regularExpression) != nil else {
                    throw URLError(.badServerResponse)
                }
                try await action("/session/" + id)
                if deviceID == target { status = "iPhone USB 控制指令已执行。" }
            } catch {
                stopIOSControl()
                if deviceID == target {
                    status = "无法执行 iPhone 触控。请确认已为这台手机签名并运行 WebDriverAgent（端口 8100）。"
                }
            }
        }
    }

    private func stopIOSControl() {
        if let wdaProxy, wdaProxy.isRunning { wdaProxy.terminate() }
        wdaProxy = nil
        wdaSession = nil
    }

    func iosKey(_ name: String) {
        performIOSControl { path in
            switch name {
            case "lock":
                _ = try await self.wdaRequest("/wda/lock", body: [:])
            case "home":
                _ = try await self.wdaRequest("/wda/homescreen", body: [:])
            default:
                _ = try await self.wdaRequest(path + "/wda/pressButton", body: ["name": name])
            }
        }
    }

    func input(_ drag: DragGesture.Value, size: CGSize, image: NSBitmapImageRep) {
        if isIOS {
            let origin = drag.startLocation
            let destination = drag.location
            let moved = hypot(drag.translation.width, drag.translation.height) >= 5
            performIOSControl { path in
                let response = try await self.wdaRequest("/wda/screen")
                let value = response["value"] as? [String: Any]
                let screen = value?["screenSize"] as? [String: Double]
                let scale = value?["scale"] as? Double ?? 3
                let width = screen?["width"] ?? Double(image.pixelsWide) / scale
                let height = screen?["height"] ?? Double(image.pixelsHigh) / scale
                func x(_ point: CGPoint) -> Double { max(0, min(width - 1, point.x / size.width * width)) }
                func y(_ point: CGPoint) -> Double { max(0, min(height - 1, point.y / size.height * height)) }
                if moved {
                    _ = try await self.wdaRequest(path + "/wda/dragfromtoforduration", body: [
                        "fromX": x(origin), "fromY": y(origin), "toX": x(destination),
                        "toY": y(destination), "duration": 0.15
                    ])
                } else {
                    _ = try await self.wdaRequest(path + "/wda/tap", body: ["x": x(origin), "y": y(origin)])
                }
            }
            return
        }
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
        guard hasSelectedDevice else { return }
        if isIOS && frame == nil {
            status = "请先开始 iPhone 投屏，再录制屏幕。"
            return
        }
        let panel = NSSavePanel()
        panel.directoryURL = preferredDirectory
        panel.nameFieldStringValue = "\(isIOS ? "iPhone" : (isHarmony ? "Harmony" : "Android"))-\(Int(Date().timeIntervalSince1970)).mp4"
        panel.allowedContentTypes = [.mpeg4Movie]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if isHarmony || isIOS {
            startFrameRecording(to: url)
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

    private func startFrameRecording(to output: URL) {
        guard ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"]
            .contains(where: FileManager.default.isExecutableFile(atPath:)) else {
            status = "录屏需要 FFmpeg。请运行 brew install ffmpeg。"
            return
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
            frameRecording = (folder, output, isIOS ? 10 : 1)
            recordedFrameCount = 0
            recording = true
            status = "正在录制画面。点击「停止录制」保存无声 MP4。"
            if isIOS { recordIOSFrame(folder: folder) }
            else { recordHarmonyFrame(deviceID, folder: folder) }
        } catch {
            status = error.localizedDescription
        }
    }

    private func recordIOSFrame(folder: URL) {
        guard frameRecording?.folder == folder,
              let image = frame?.representation(using: .jpeg, properties: [.compressionFactor: 0.8]) else {
            return
        }
        do {
            let name = String(format: "%06d.jpeg", recordedFrameCount)
            try image.write(to: folder.appendingPathComponent(name), options: .atomic)
            recordedFrameCount += 1
        } catch {
            stopRecording()
            return
        }
        Task {
            try? await Task.sleep(for: .milliseconds(100))
            if frameRecording?.folder == folder { recordIOSFrame(folder: folder) }
        }
    }

    private func recordHarmonyFrame(_ id: String, folder: URL) {
        captureHarmony(id, jpeg: true) { code, data, _ in
            guard self.frameRecording?.folder == folder else { return }
            guard code == 0, NSBitmapImageRep(data: data) != nil else {
                self.stopRecording()
                return
            }
            do {
                let name = String(format: "%06d.jpeg", self.recordedFrameCount)
                try data.write(to: folder.appendingPathComponent(name), options: .atomic)
                self.recordedFrameCount += 1
            } catch {
                self.stopRecording()
                return
            }
            Task {
                try? await Task.sleep(for: .milliseconds(80))
                guard self.frameRecording?.folder == folder else { return }
                self.recordHarmonyFrame(id, folder: folder)
            }
        }
    }

    func stopRecording() {
        guard let session = frameRecording else {
            if let recorder, recorder.isRunning { recorder.interrupt() }
            return
        }
        frameRecording = nil
        guard recordedFrameCount > 0 else {
            try? FileManager.default.removeItem(at: session.folder)
            recording = false
            status = "录屏未取得画面。"
            return
        }
        status = "正在生成录屏…"
        let video = session.folder.appendingPathComponent("recording.mp4")
        run("ffmpeg", ["-v", "error", "-framerate", String(session.fps), "-i",
                       session.folder.appendingPathComponent("%06d.jpeg").path,
                       "-vf", "scale=720:1280:force_original_aspect_ratio=decrease,pad=720:1280:(ow-iw)/2:(oh-ih)/2",
                       "-c:v", "libx264", "-pix_fmt", "yuv420p", video.path]) { code, _, error in
            defer {
                self.recording = false
                try? FileManager.default.removeItem(at: session.folder)
            }
            guard code == 0 else {
                self.status = "录屏生成失败。\n" + error
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
        if isIOS {
            exportIOSLogs()
            return
        }
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

    private func exportIOSLogs() {
        let panel = NSSavePanel()
        panel.directoryURL = preferredDirectory
        panel.nameFieldStringValue = "iPhone-syslog-\(Int(Date().timeIntervalSince1970)).txt"
        panel.allowedContentTypes = [.plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        exportingLogs = true
        status = "正在收集 iPhone 最近 5 秒的实时日志…"
        run("idevicesyslog", ["-u", deviceID, "-x", "--no-colors"], timeout: .seconds(5)) { _, data, error in
            defer { self.exportingLogs = false }
            guard !data.isEmpty else {
                self.status = "未收到 iPhone 实时日志。\n" + error
                return
            }
            do {
                try data.write(to: url, options: .atomic)
                self.status = "iPhone 日志已保存到 \(url.lastPathComponent)"
            } catch {
                self.status = "保存日志失败。\n" + error.localizedDescription
            }
        }
    }

    func screenshot() {
        let panel = NSSavePanel()
        panel.directoryURL = preferredDirectory
        let platform = isIOS ? "iPhone" : (isHarmony ? "Harmony" : "Android")
        panel.nameFieldStringValue = "\(platform)-\(Int(Date().timeIntervalSince1970)).png"
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
        if isIOS, let png = frame?.representation(using: .png, properties: [.gamma: 0.45455]) {
            save(0, png, "")
        } else if isIOS {
            let temporary = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString + ".png")
            run("idevicescreenshot", ["-u", deviceID, temporary.path]) { code, output, error in
                defer { try? FileManager.default.removeItem(at: temporary) }
                let data = (try? Data(contentsOf: temporary)) ?? Data()
                if data.isEmpty {
                    self.saving = false
                    self.status = "iPhone 截图服务不可用。\n" + error + String(decoding: output, as: UTF8.self)
                } else {
                    save(code, data, error)
                }
            }
        } else if isHarmony {
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
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
        WindowGroup("Phone Studio") {
            HStack(spacing: 0) {
                if !previewExpanded {
                    sidebarPanel(width: 200, leading: true, collapsed: $directoryCollapsed) {
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
        .commands {
            CommandGroup(after: .appInfo) {
                if Bundle.main.object(forInfoDictionaryKey: "StudioLocalSource") != nil {
                    Button("从本地项目升级…", action: updateInstalledApp)
                }
            }
        }
    }

    private func updateInstalledApp() {
        guard let root = Bundle.main.object(forInfoDictionaryKey: "StudioLocalSource") as? String else { return }
        let script = URL(fileURLWithPath: root).appendingPathComponent("run.sh")
        guard FileManager.default.isExecutableFile(atPath: script.path) else {
            showUpdateError("找不到原项目的启动脚本。")
            return
        }
        let process = Process()
        process.executableURL = script
        process.arguments = ["--install"]
        let errors = Pipe()
        process.standardError = errors
        process.terminationHandler = { process in
            guard process.terminationStatus != 0 else { return }
            let details = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            Task { @MainActor in showUpdateError(details) }
        }
        do {
            try process.run()
        } catch {
            showUpdateError(error.localizedDescription)
        }
    }

    private func showUpdateError(_ details: String) {
        let alert = NSAlert()
        alert.messageText = "无法升级 Phone Studio"
        alert.informativeText = details
        alert.runModal()
    }

    private var directory: some View {
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
                Button(action: updateInstalledApp) {
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

    private func sidebarPanel<Content: View>(width: CGFloat, leading: Bool,
                                              collapsed: Binding<Bool>,
                                              @ViewBuilder content: () -> Content) -> some View {
        let hidden = collapsed.wrappedValue
        let edge: Alignment = leading ? .trailing : .leading
        let name = leading ? "导航" : "功能"
        let arrow = leading == hidden ? "chevron.right" : "chevron.left"

        return Rectangle()
            .fill(.clear)
            .frame(width: hidden ? 22 : width)
            .overlay(alignment: edge) {
                content()
                    .frame(width: width)
                    .offset(x: hidden ? (leading ? -22 : 22) : 0)
                    .allowsHitTesting(!hidden)
                    .accessibilityHidden(hidden)
            }
            .clipped()
            .overlay(alignment: edge) {
                Button {
                    withAnimation(reduceMotion ? nil : .smooth(duration: 0.27, extraBounce: 0)) {
                        collapsed.wrappedValue.toggle()
                    }
                } label: {
                    Image(systemName: arrow)
                        .font(.system(size: 9, weight: .semibold))
                        .frame(width: 20, height: 42)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 5))
                }
                .buttonStyle(.plain)
                .accessibilityLabel((hidden ? "展开" : "收起") + name)
                .help((hidden ? "展开" : "收起") + name)
            }
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

    private var landing: some View {
        VStack(alignment: .leading, spacing: 18) {
            let home = page == .home
            toolCard(nil) {
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
                        sidebarPanel(width: max(268, geometry.size.width * 0.40),
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

    private var tools: some View {
        ScrollView {
            VStack(spacing: 9) {
                toolCard("按键区") {
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
                toolCard("设备/应用信息") {
                    HStack(spacing: 6) {
                        tile("安装应用", "square.and.arrow.down", phone.install)
                        tile("卸载应用", "trash", phone.uninstall)
                        tile("应用信息", "square.grid.2x2", phone.listApps)
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
                if !phone.isIOS {
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

    private func toolCard<Content: View>(_ title: String?,
                                         @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title { Text(title).font(.system(size: 15, weight: .semibold)) }
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
