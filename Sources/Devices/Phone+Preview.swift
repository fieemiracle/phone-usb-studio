import AppKit
import AVFoundation

extension Phone {
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

    func captureHarmony(_ id: String, jpeg: Bool = false,
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
}
