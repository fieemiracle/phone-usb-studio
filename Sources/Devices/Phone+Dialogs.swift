import AppKit
import SwiftUI

extension Phone {
    func ask(_ title: String, prompt: String, initial: String = "") -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = prompt
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.stringValue = initial
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        alert.addButton(withTitle: "确认")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var preferredDirectory: URL? {
        if !outputDirectory.isEmpty { return URL(fileURLWithPath: outputDirectory, isDirectory: true) }
        return FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
    }

    func chooseOutputDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.directoryURL = preferredDirectory
        panel.prompt = "设为保存目录"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        outputDirectory = url.path
        status = "默认保存目录：\(url.path)"
    }
}
