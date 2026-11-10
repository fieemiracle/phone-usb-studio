import SwiftUI

@MainActor
func sidebarButton(_ title: String, icon: String,
                           action: @escaping () -> Void) -> some View {
    Button(action: action) {
        Image(systemName: icon)
            .frame(width: 26, height: 26)
            .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .help(title)
    .accessibilityLabel(title)
}
