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
    @Published var harmonyDevices: [String] = []
    @Published var iosDevices: [String] = []
    @Published var iosModels: [String: String] = [:]
    @Published var deviceID = "" {
        didSet { if deviceID != oldValue { stopIOSControl() } }
    }
    @Published var osVersions: [String: String] = [:]
    @Published var quality = 20
    var previewID = UUID()
    var recorder: Process?
    var frameRecording: (folder: URL, output: URL, fps: Int)?
    var recordedFrameCount = 0
    @AppStorage("outputDirectory") var outputDirectory = ""
    var previewProcess: Process?
    var iosCapture: IOSScreenCapture?
    var wdaProxy: Process?
    var wdaPort = 0
    var wdaSession: String?
    var wdaBusy = false
    var iosPreviewDeviceID: String?
    var scanningDevices = false
    var loadingVersions: Set<String> = []
    @Published var harmonyModels: [String: String] = [:]

    var isHarmony: Bool { harmonyDevices.contains(deviceID) }
    var isIOS: Bool { iosPreviewDeviceID == deviceID || iosDevices.contains(deviceID) }
    var hasSelectedDevice: Bool { isIOS || isHarmony || devices.contains { $0.id == deviceID } }

    func run(_ tool: String, _ arguments: [String], timeout: Duration? = nil,
             completion: @escaping @MainActor (Int32, Data, String) -> Void) {
        let targetArguments = arguments.first == "-d" && !deviceID.isEmpty
            ? ["-s", deviceID] + Array(arguments.dropFirst()) : arguments
        let process = ToolProcess.run(tool, arguments: targetArguments, timeout: timeout, completion: completion)
        if tool == "scrcpy", let process { recorder = process }
    }
}
