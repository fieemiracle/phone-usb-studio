import AVFoundation
import CoreImage
import CoreMediaIO

final class IOSScreenCapture: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
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
