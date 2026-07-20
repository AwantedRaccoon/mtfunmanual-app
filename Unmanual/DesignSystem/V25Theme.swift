import SwiftUI

/// V2.5 只定义布局与交互参数；颜色全部来自 AppTheme 语义令牌。
enum V25Theme {
    static let pagePadding: CGFloat = 18
    static let contentWidth: CGFloat = 560
    static let fieldSpacing: CGFloat = 14
    static let sectionSpacing: CGFloat = 24
    static let controlHeight: CGFloat = 52
    static let dayValueLeadingInset: CGFloat = 16
}

struct V25PressStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .offset(y: configuration.isPressed && !reduceMotion ? 3 : 0)
            .opacity(configuration.isPressed ? 0.74 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: configuration.isPressed)
    }
}
