import Foundation

@MainActor
enum ToolProcess {
    static func run(_ tool: String, arguments: [String], timeout: Duration? = nil,
                     completion: @escaping @MainActor (Int32, Data, String) -> Void) -> Process? {
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
            return nil
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
            if let timeout {
                Task {
                    try? await Task.sleep(for: timeout)
                    if process.isRunning { process.interrupt() }
                }
            }
            return process
        } catch {
            try? FileManager.default.removeItem(at: directory)
            completion(1, Data(), error.localizedDescription)
            return nil
        }
    }
}
