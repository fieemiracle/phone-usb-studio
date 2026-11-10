import SwiftUI

struct SidebarPanel<Content: View>: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let width: CGFloat
    let leading: Bool
    @Binding var collapsed: Bool
    @ViewBuilder let content: Content

    var body: some View {
        let hidden = collapsed
        let edge: Alignment = leading ? .trailing : .leading
        let name = leading ? "导航" : "功能"
        let arrow = leading == hidden ? "chevron.right" : "chevron.left"

        Rectangle()
            .fill(.clear)
            .frame(width: hidden ? 22 : width)
            .overlay(alignment: edge) {
                content
                    .frame(width: width)
                    .offset(x: hidden ? (leading ? -22 : 22) : 0)
                    .allowsHitTesting(!hidden)
                    .accessibilityHidden(hidden)
            }
            .clipped()
            .overlay(alignment: edge) {
                Button {
                    withAnimation(reduceMotion ? nil : .smooth(duration: 0.27, extraBounce: 0)) {
                        collapsed.toggle()
                    }
                } label: {
                    Image(systemName: arrow)
                        .font(.system(size: 9, weight: .semibold))
                        .frame(width: 20, height: 42)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 5))
                }
                .buttonStyle(.plain)
                .accessibilityLabel((hidden ? "展开" : "收起") + name)
                .help((hidden ? "展开" : "收起") + name)
            }
    }
}
