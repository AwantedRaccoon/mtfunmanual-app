import SwiftUI

/// V2.5 只定义布局与交互参数；颜色全部来自 AppTheme 语义令牌。
enum V25Theme {
    static let pagePadding: CGFloat = 18
    static let contentWidth: CGFloat = 560
    static let tabBarClearance: CGFloat = 72
    static let accessibilityTabBarClearance: CGFloat = 252
    static let accessibilityTabBarBottomPadding: CGFloat = 12
    static let accessibilityTabLabelBottomPadding: CGFloat = 8
    static let tabBarMaximumDynamicTypeSize: DynamicTypeSize = .accessibility2
    static let fieldSpacing: CGFloat = 14
    static let sectionSpacing: CGFloat = 24
    static let controlHeight: CGFloat = 52
    static let dayValueLeadingInset: CGFloat = 16
}

private struct V25ReduceMotionOverrideKey: EnvironmentKey {
    static let defaultValue: Bool? = nil
}

extension EnvironmentValues {
    var v25ReduceMotionOverride: Bool? {
        get { self[V25ReduceMotionOverrideKey.self] }
        set { self[V25ReduceMotionOverrideKey.self] = newValue }
    }
}

struct V25PressStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.v25ReduceMotionOverride) private var reduceMotionOverride

    private var shouldReduceMotion: Bool { reduceMotionOverride ?? reduceMotion }

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .offset(y: configuration.isPressed && !shouldReduceMotion ? 3 : 0)
            .opacity(configuration.isPressed ? 0.74 : 1)
            .animation(
                shouldReduceMotion ? nil : .easeOut(duration: 0.16),
                value: configuration.isPressed
            )
    }
}
