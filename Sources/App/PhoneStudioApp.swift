import SwiftUI

@main
struct PhoneStudioApp: App {
    @StateObject private var phone = Phone()

    var body: some Scene {
        WindowGroup("Phone Studio") {
            StudioWindow(phone: phone)
        }
        .defaultSize(width: 1350, height: 820)
        .commands {
            CommandGroup(after: .appInfo) {
                if Bundle.main.object(forInfoDictionaryKey: "StudioLocalSource") != nil {
                    Button("从本地项目升级…", action: LocalAppUpdater.install)
                }
            }
        }
    }
}
