import AppKit
import SwiftUI

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

    func stopIOSControl() {
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
}
