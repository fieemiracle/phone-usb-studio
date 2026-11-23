import AppKit
import SwiftUI

@MainActor
final class DeviceConsole: ObservableObject {
    @Published var lines: [String] = []
    @Published var message = ""
    @Published var paused = false
    private var process: Process?
    private var reader: Task<Void, Never>?
    private var generation = UUID()

    func stop() {
        generation = UUID()
        reader?.cancel()
        reader = nil
        if let process, process.isRunning { process.terminate() }
        process = nil
    }

    func start(phone: Phone) {
        stop()
        lines = []
        paused = false
        guard phone.hasSelectedDevice else { message = "请选择已连接的设备。"; return }
        let tool = phone.isIOS ? "idevicesyslog" : phone.isHarmony ? "hdc" : "adb"
        var locations = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"]
        if tool == "hdc" {
            let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/lib/hdc")
            locations += ((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? [])
                .sorted(by: >).map { root.appendingPathComponent($0).path }
        }
        guard let executable = locations.map({ "\($0)/\(tool)" })
            .first(where: FileManager.default.isExecutableFile(atPath:)) else {
            message = "找不到日志工具 \(tool)。"
            return
        }
        let arguments = phone.isIOS ? ["-u", phone.deviceID, "--no-colors"] :
            phone.isHarmony ? ["-t", phone.deviceID, "shell", "hilog"] :
            ["-s", phone.deviceID, "logcat", "-T", "1", "-v", "threadtime"]
        let taskID = generation
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
            self.process = process
            message = "正在采集 · 最多保留 3000 行"
            reader = Task.detached { [weak self] in
                let handle = pipe.fileHandleForReading
                defer { try? handle.close() }
                var pending = Data()
                while !Task.isCancelled {
                    let chunk = handle.availableData
                    if chunk.isEmpty { break }
                    pending.append(chunk)
                    var batch: [String] = []
                    while let newline = pending.firstIndex(of: 10) {
                        batch.append(String(decoding: pending[..<newline], as: UTF8.self))
                        pending.removeSubrange(...newline)
                    }
                    if pending.count > 65536 {
                        batch.append(String(decoding: pending, as: UTF8.self))
                        pending.removeAll()
                    }
                    await self?.append(batch, generation: taskID)
                    try? await Task.sleep(for: .milliseconds(200))
                }
                if !pending.isEmpty {
                    await self?.append([String(decoding: pending, as: UTF8.self)], generation: taskID)
                }
                await self?.ended(generation: taskID)
            }
        } catch {
            message = "无法启动日志采集：\(error.localizedDescription)"
        }
    }

    private func append(_ batch: [String], generation: UUID) {
        guard self.generation == generation, !paused, !batch.isEmpty else { return }
        lines.append(contentsOf: batch)
        if lines.count > 3000 { lines.removeFirst(lines.count - 3000) }
    }

    private func ended(generation: UUID) {
        guard self.generation == generation else { return }
        message = "日志流已结束，请检查连接后重连。"
    }
}
