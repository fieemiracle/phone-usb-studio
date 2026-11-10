import AppKit

@MainActor
enum LocalAppUpdater {
    static func install() {
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

    private static func showUpdateError(_ details: String) {
        let alert = NSAlert()
        alert.messageText = "无法升级 Phone Studio"
        alert.informativeText = details
        alert.runModal()
    }
}
