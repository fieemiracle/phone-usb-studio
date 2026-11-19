import AppKit
import SwiftUI

private struct WDAError: LocalizedError {
    let detail: String
    var errorDescription: String? { detail }
}

extension Phone {
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
              let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        let value = payload["value"] as? [String: Any]
        if !(200..<300).contains(http.statusCode) || value?["error"] is String {
            throw WDAError(detail: value?["message"] as? String ?? "HTTP \(http.statusCode) \(path)")
        }
        return payload
    }

    private func startWDAProxy(device: String) async throws {
        guard wdaProxy?.isRunning != true else { return }
        guard let executable = ["/opt/homebrew/bin/iproxy", "/usr/local/bin/iproxy"]
            .first(where: FileManager.default.isExecutableFile(atPath:)) else {
            throw WDAError(detail: "找不到 iproxy。请安装 libusbmuxd。")
        }
        let process = Process()
        wdaPort = Int.random(in: 49152...65535)
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["-l", "-s", "127.0.0.1", "-u", device, "\(wdaPort):8100"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        wdaProxy = process
        try await Task.sleep(for: .milliseconds(250))
        guard process.isRunning else { throw URLError(.cannotConnectToHost) }
    }

    func startIOSControl(device: String, preview: UUID) {
        wdaStartup = Task {
            defer { if previewID == preview { wdaStartup = nil } }
            do {
                try await startWDAProxy(device: device)
                try Task.checkCancellation()
                if await wdaReady() {
                    if !Task.isCancelled { status += "\n触控服务已连接。" }
                    return
                }
                try Task.checkCancellation()
                let root = URL.applicationSupportDirectory.appending(path: "Phone USB Studio/WebDriverAgent")
                let project = root.appending(path: "WebDriverAgent.xcodeproj").path
                guard FileManager.default.fileExists(atPath: project) else {
                    throw WDAError(detail: "本机尚未配置已签名的 WebDriverAgent。")
                }
                wdaRunner = ToolProcess.run("xcodebuild", arguments: [
                    "-project", project, "-scheme", "WebDriverAgentRunner",
                    "-destination", "platform=iOS,id=\(device.uppercased())", "-destination-timeout", "15", "-derivedDataPath", root.appending(path: "BuildCache").path,
                    "test-without-building"
                ]) { [weak self] code, output, error in
                    guard let self, self.previewID == preview, self.deviceID == device else { return }
                    let log = String(decoding: output, as: UTF8.self) + "\n" + error
                    let detail = log.split(whereSeparator: \.isNewline).last {
                        $0.contains("Underlying Error") || $0.contains("error:")
                    }.map(String.init)
                    self.status += "\n触控服务已退出（\(code)）。\(detail ?? "")\n" + log.suffix(1800)
                }
                for _ in 0..<45 {
                    try await Task.sleep(for: .seconds(1))
                    guard wdaRunner?.isRunning == true else { return }
                    if await wdaReady() {
                        if !Task.isCancelled { status += "\n触控服务已连接。" }
                        return
                    }
                }
                throw WDAError(detail: "触控服务启动超时，请保持 iPhone 解锁并重新开始投屏。")
            } catch {
                guard !Task.isCancelled, previewID == preview, deviceID == device else { return }
                status += "\n触控服务启动失败：\(error.localizedDescription)"
            }
        }
    }

    private func wdaReady() async -> Bool {
        guard let payload = try? await wdaRequest("/status") else { return false }
        return (payload["value"] as? [String: Any])?["ready"] as? Bool == true
    }

    private func performIOSControl(_ action: @escaping @MainActor (String) async throws -> Void) {
        guard isIOS, !wdaBusy else { return }
        guard wdaStartup == nil else {
            status = "正在启动 iPhone 触控服务，请稍候…"
            return
        }
        let target = deviceID
        let preview = previewID
        wdaBusy = true
        Task {
            defer { wdaBusy = false }
            do {
                try await startWDAProxy(device: target)
                guard deviceID == target, previewID == preview, wdaProxy?.isRunning == true else { return }
                if wdaSession == nil {
                    let reply = try await wdaRequest("/session", body: [
                        "capabilities": ["alwaysMatch": ["shouldTerminateApp": false], "firstMatch": [[:]]]
                    ])
                    guard deviceID == target, previewID == preview else { return }
                    let value = reply["value"] as? [String: Any]
                    wdaSession = (value?["sessionId"] as? String) ?? (reply["sessionId"] as? String)
                }
                guard deviceID == target, let id = wdaSession,
                      id.range(of: #"^[A-Za-z0-9-]+$"#, options: .regularExpression) != nil else {
                    throw URLError(.badServerResponse)
                }
                try await action("/session/" + id)
                if deviceID == target, previewID == preview { status = "iPhone USB 控制指令已执行。" }
            } catch {
                guard deviceID == target, previewID == preview else { return }
                wdaSession = nil
                status = "iPhone 触控失败：\(error.localizedDescription)\n请确认手机已解锁，且 WebDriverAgentRunner 测试正在运行（端口 8100）。"
            }
        }
    }

    func stopIOSControl() {
        wdaStartup?.cancel()
        wdaStartup = nil
        if let wdaRunner, wdaRunner.isRunning { wdaRunner.interrupt() }
        wdaRunner = nil
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

    func input(_ drag: DragGesture.Value, size: CGSize, image: NSBitmapImageRep, heldFor: Duration = .zero) {
        guard size.width > 0, size.height > 0 else { return }
        if isIOS {
            let origin = drag.startLocation
            let destination = drag.location
            let target = deviceID
            let preview = previewID
            let moved = hypot(drag.translation.width, drag.translation.height) >= 5
            performIOSControl { path in
                let response = try await self.wdaRequest(path + "/wda/screen")
                guard self.deviceID == target, self.previewID == preview else { return }
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
                } else if heldFor >= .milliseconds(500) {
                    _ = try await self.wdaRequest(path + "/wda/touchAndHold", body: [
                        "x": x(origin), "y": y(origin), "duration": 0.6
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
}
