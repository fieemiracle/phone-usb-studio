import SwiftUI

struct StudioWindow: View {
    @ObservedObject var phone: Phone

    @State var page: Page = .home
    @State var previewExpanded = false
    @State var directoryCollapsed = false
    @State var toolsCollapsed = false
    @State var zoom = 1.0
    @State var deviceMenuOpen = false
    @State var shellCommand = ""
    let blue = Color(red: 0, green: 0.49, blue: 1)

    enum Page {
        case home, utilities, mirroring
    }

    var body: some View {
        HStack(spacing: 0) {
            if !previewExpanded {
                SidebarPanel(width: 200, leading: true, collapsed: $directoryCollapsed) {
                    directory
                }
            }
            switch page {
            case .home, .utilities:
                landing
            case .mirroring:
                MirroringWorkspace(phone: phone, previewExpanded: $previewExpanded,
                                   toolsCollapsed: $toolsCollapsed, zoom: $zoom,
                                   deviceMenuOpen: $deviceMenuOpen, shellCommand: $shellCommand) {
                    page = .utilities
                    previewExpanded = false
                }
            }
        }
        .frame(minWidth: 850, minHeight: 570)
        .onDisappear {
            phone.stop()
            phone.stopRecording()
        }
    }
}
