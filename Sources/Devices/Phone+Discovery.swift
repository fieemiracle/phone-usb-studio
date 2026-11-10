import Foundation

extension Phone {
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
}
