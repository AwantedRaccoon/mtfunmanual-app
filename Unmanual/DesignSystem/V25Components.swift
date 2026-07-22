import SwiftUI

struct V25Page<Content: View>: View {
    @Environment(AppTheme.self) private var theme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                content
                    .frame(
                        width: min(
                            V25Theme.contentWidth,
                            max(0, geometry.size.width - V25Theme.pagePadding * 2)
                        ),
                        alignment: .leading
                    )
                    .padding(.horizontal, V25Theme.pagePadding)
                    .padding(
                        .bottom,
                        30 + (dynamicTypeSize.isAccessibilitySize
                            ? V25Theme.accessibilityTabBarClearance
                            : V25Theme.tabBarClearance)
                    )
                    .frame(maxWidth: .infinity)
            }
            .scrollIndicators(.hidden)
            .overlay(alignment: .top) {
                theme.rice
                    .frame(height: geometry.safeAreaInsets.top)
                    .ignoresSafeArea(edges: .top)
                    .allowsHitTesting(false)
            }
        }
        .background(theme.rice.ignoresSafeArea())
    }
}

struct V25PageHeader: View {
    @Environment(AppTheme.self) private var theme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let register: String
    let title: String
    let subtitle: String
    let status: String

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 8) {
                    Text(register.uppercased())
                        .font(.caption.weight(.bold))
                        .tracking(0.8)
                    Text(title)
                        .font(.title2.weight(.black))
                        .fixedSize(horizontal: false, vertical: true)
                    Text(subtitle)
                        .font(.body)
                        .foregroundStyle(theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(status)
                        .font(.caption.weight(.bold))
                        .foregroundStyle(theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                HStack(alignment: .top, spacing: 18) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(title)
                            .font(theme.display(42, relativeTo: .largeTitle))
                            .tracking(-1.2)
                        Text(subtitle)
                            .font(.subheadline)
                            .foregroundStyle(theme.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer(minLength: 8)

                    VStack(alignment: .trailing, spacing: 6) {
                        Text(register.uppercased())
                            .font(theme.utility(10))
                            .tracking(0.9)
                        Text(status)
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(theme.secondaryText)
                    }
                    .padding(.top, 9)
                }
            }
        }
        .foregroundStyle(theme.indigoDeep)
        .padding(.top, 8)
        .padding(.bottom, 15)
        .overlay(alignment: .bottom) {
            Rectangle().fill(theme.indigo).frame(height: 2)
        }
        .accessibilityElement(children: .combine)
    }
}

struct V25SectionHeader: View {
    @Environment(AppTheme.self) private var theme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let title: String
    let detail: String

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 5) {
                    Text(title)
                        .font(.headline.weight(.black))
                    Text(detail.uppercased())
                        .font(.caption.weight(.bold))
                        .foregroundStyle(theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                HStack(alignment: .lastTextBaseline, spacing: 12) {
                    Text(title)
                        .font(.headline.weight(.black))
                    Spacer()
                    Text(detail.uppercased())
                        .font(theme.utility(9))
                        .tracking(0.8)
                        .foregroundStyle(theme.secondaryText)
                }
            }
        }
        .foregroundStyle(theme.indigoDeep)
        .padding(.top, 18)
        .padding(.bottom, 9)
    }
}

struct V25FieldSurface<Content: View>: View {
    @Environment(AppTheme.self) private var theme

    let label: String
    let note: String?
    let labelColor: Color?
    private let content: Content

    init(
        _ label: String,
        note: String? = nil,
        labelColor: Color? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.label = label
        self.note = note
        self.labelColor = labelColor
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(label)
                .font(.caption.weight(.black))
                .foregroundStyle(labelColor ?? theme.vermilionText)

            content
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)

            if let note {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .foregroundStyle(theme.indigoDeep)
        .padding(14)
        .background(theme.paper)
        .overlay { Rectangle().stroke(theme.indigo, lineWidth: 1.5) }
    }
}

struct V25EditorHeader: View {
    @Environment(AppTheme.self) private var theme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let register: String
    let cancel: () -> Void

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 4) {
                    Button("取消", action: cancel)
                        .font(.body.weight(.semibold))
                        .frame(minWidth: 44, minHeight: 44, alignment: .leading)
                        .buttonStyle(.plain)
                    Text(register.uppercased())
                        .font(.caption2.weight(.bold))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                HStack {
                    Button("取消", action: cancel)
                        .font(.body.weight(.semibold))
                        .frame(minWidth: 44, minHeight: 44, alignment: .leading)
                        .buttonStyle(.plain)

                    Spacer()

                    Text(register.uppercased())
                        .font(theme.utility(10))
                        .tracking(0.9)
                }
            }
        }
        .foregroundStyle(theme.indigo)
        .overlay(alignment: .bottom) {
            Rectangle().fill(theme.indigo).frame(height: 1)
        }
    }
}

struct V25EditorIntro: View {
    @Environment(AppTheme.self) private var theme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let eyebrow: String
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(eyebrow.uppercased())
                .font(dynamicTypeSize.isAccessibilitySize ? .caption.weight(.bold) : theme.utility(10))
                .tracking(dynamicTypeSize.isAccessibilitySize ? 0 : 0.9)
                .foregroundStyle(theme.vermilionText)
            Text(title)
                .font(dynamicTypeSize.isAccessibilitySize ? .title2.weight(.black) : theme.display(34, relativeTo: .largeTitle))
                .foregroundStyle(theme.indigoDeep)
                .fixedSize(horizontal: false, vertical: true)
            Text(detail)
                .font(dynamicTypeSize.isAccessibilitySize ? .body : .subheadline)
                .foregroundStyle(theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct V25EditorPage<Content: View>: View {
    @Environment(AppTheme.self) private var theme

    let register: String
    let eyebrow: String
    let title: String
    let detail: String
    let cancel: () -> Void
    private let content: Content

    init(
        register: String,
        eyebrow: String,
        title: String,
        detail: String,
        cancel: @escaping () -> Void,
        @ViewBuilder content: () -> Content
    ) {
        self.register = register
        self.eyebrow = eyebrow
        self.title = title
        self.detail = detail
        self.cancel = cancel
        self.content = content()
    }

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: V25Theme.sectionSpacing) {
                    V25EditorHeader(register: register, cancel: cancel)
                    V25EditorIntro(eyebrow: eyebrow, title: title, detail: detail)
                    content
                }
                .frame(
                    width: min(
                        V25Theme.contentWidth,
                        max(0, geometry.size.width - V25Theme.pagePadding * 2)
                    ),
                    alignment: .leading
                )
                .padding(.horizontal, V25Theme.pagePadding)
                .padding(.bottom, 24)
                .frame(maxWidth: .infinity)
            }
            .defaultScrollAnchor(.top)
            .scrollDismissesKeyboard(.interactively)
            .scrollIndicators(.hidden)
        }
        .background(theme.rice.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
    }
}

struct V25SaveBar: View {
    @Environment(AppTheme.self) private var theme

    let title: String
    let isEnabled: Bool
    let accessibilityIdentifier: String
    let action: () -> Void

    var body: some View {
        Button(title, action: action)
            .buttonStyle(V25PrimaryButtonStyle())
            .disabled(!isEnabled)
            .opacity(isEnabled ? 1 : 0.46)
            .accessibilityIdentifier(accessibilityIdentifier)
            .padding(.horizontal, V25Theme.pagePadding)
            .padding(.top, 10)
            .padding(.bottom, 8)
            .background(theme.rice)
            .overlay(alignment: .top) {
                Rectangle().fill(theme.indigo).frame(height: 1)
            }
    }
}

struct V25EmptyState: View {
    @Environment(AppTheme.self) private var theme

    let eyebrow: String
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(eyebrow.uppercased())
                .font(theme.utility(10))
                .tracking(0.8)
                .foregroundStyle(theme.vermilionText)
            Text(title)
                .font(theme.display(27, relativeTo: .title2))
            Text(detail)
                .font(.body)
                .foregroundStyle(theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(theme.indigoDeep)
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.paper)
        .overlay { Rectangle().stroke(theme.indigo, lineWidth: 1.5) }
    }
}

struct V25PrivacyFooter: View {
    @Environment(AppTheme.self) private var theme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "lock.fill")
                .accessibilityHidden(true)
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
        }
            .font(dynamicTypeSize.isAccessibilitySize ? .caption.weight(.bold) : theme.utility(9))
            .tracking(dynamicTypeSize.isAccessibilitySize ? 0 : 0.7)
            .foregroundStyle(theme.secondaryText)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 14)
            .accessibilityElement(children: .combine)
    }
}

struct V25PrimaryButtonStyle: ButtonStyle {
    @Environment(AppTheme.self) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.v25ReduceMotionOverride) private var reduceMotionOverride

    private var shouldReduceMotion: Bool { reduceMotionOverride ?? reduceMotion }

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline.weight(.black))
            .foregroundStyle(theme.paper)
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity, minHeight: V25Theme.controlHeight)
            .background(theme.indigo)
            .overlay { Rectangle().stroke(theme.indigo, lineWidth: 2) }
            .offset(y: configuration.isPressed && !shouldReduceMotion ? 2 : 0)
            .opacity(configuration.isPressed ? 0.75 : 1)
            .animation(
                shouldReduceMotion ? nil : .easeOut(duration: 0.16),
                value: configuration.isPressed
            )
    }
}

struct V25SecondaryButtonStyle: ButtonStyle {
    @Environment(AppTheme.self) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.v25ReduceMotionOverride) private var reduceMotionOverride

    private var shouldReduceMotion: Bool { reduceMotionOverride ?? reduceMotion }

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.bold))
            .foregroundStyle(theme.indigo)
            .padding(.horizontal, 14)
            .frame(minHeight: 44)
            .background(theme.paper)
            .overlay { Rectangle().stroke(theme.indigo, lineWidth: 1.5) }
            .offset(y: configuration.isPressed && !shouldReduceMotion ? 2 : 0)
            .opacity(configuration.isPressed ? 0.72 : 1)
            .animation(
                shouldReduceMotion ? nil : .easeOut(duration: 0.16),
                value: configuration.isPressed
            )
    }
}

extension View {
    func localSaveErrorAlert(message: Binding<String?>) -> some View {
        alert(
            "没有保存",
            isPresented: Binding(
                get: { message.wrappedValue != nil },
                set: { isPresented in
                    if !isPresented {
                        message.wrappedValue = nil
                    }
                }
            )
        ) {
            Button("返回检查", role: .cancel) {
                message.wrappedValue = nil
            }
        } message: {
            Text(message.wrappedValue ?? "请检查后再试。")
        }
    }
}
