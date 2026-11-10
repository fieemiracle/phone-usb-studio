import AppKit
import SwiftUI

extension Phone {
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
