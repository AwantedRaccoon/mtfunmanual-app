import SwiftUI

struct V25Page<Content: View>: View {
    @Environment(AppTheme.self) private var theme

    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                content
                    .padding(.horizontal, V25Theme.pagePadding)
                    .padding(.bottom, 30)
                    .frame(maxWidth: V25Theme.contentWidth)
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
                        .font(theme.utility(11))
                        .tracking(0.8)
                    Text(title)
                        .font(theme.display(38, relativeTo: .largeTitle))
                    Text(subtitle)
                        .font(.body)
                        .foregroundStyle(theme.indigo.opacity(0.7))
                    Text(status)
                        .font(.caption.weight(.bold))
                        .foregroundStyle(theme.indigo.opacity(0.62))
                }
            } else {
                HStack(alignment: .top, spacing: 18) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(title)
                            .font(theme.display(42, relativeTo: .largeTitle))
                            .tracking(-1.2)
                        Text(subtitle)
                            .font(.subheadline)
                            .foregroundStyle(theme.indigo.opacity(0.68))
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer(minLength: 8)

                    VStack(alignment: .trailing, spacing: 6) {
                        Text(register.uppercased())
                            .font(theme.utility(10))
                            .tracking(0.9)
                        Text(status)
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(theme.indigo.opacity(0.58))
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

    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .lastTextBaseline, spacing: 12) {
            Text(title)
                .font(.headline.weight(.black))
            Spacer()
            Text(detail.uppercased())
                .font(theme.utility(9))
                .tracking(0.8)
                .foregroundStyle(theme.indigo.opacity(0.58))
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
                .foregroundStyle(labelColor ?? theme.vermilion)

            content
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)

            if let note {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(theme.indigo.opacity(0.62))
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

    let register: String
    let cancel: () -> Void

    var body: some View {
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
        .foregroundStyle(theme.indigo)
        .overlay(alignment: .bottom) {
            Rectangle().fill(theme.indigo).frame(height: 1)
        }
    }
}

struct V25EditorIntro: View {
    @Environment(AppTheme.self) private var theme

    let eyebrow: String
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(eyebrow.uppercased())
                .font(theme.utility(10))
                .tracking(0.9)
                .foregroundStyle(theme.vermilion)
            Text(title)
                .font(theme.display(34, relativeTo: .largeTitle))
                .foregroundStyle(theme.indigoDeep)
            Text(detail)
                .font(.subheadline)
                .foregroundStyle(theme.indigo.opacity(0.68))
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
        ScrollView {
            VStack(alignment: .leading, spacing: V25Theme.sectionSpacing) {
                V25EditorHeader(register: register, cancel: cancel)
                V25EditorIntro(eyebrow: eyebrow, title: title, detail: detail)
                content
            }
            .padding(.horizontal, V25Theme.pagePadding)
            .padding(.bottom, 24)
            .frame(maxWidth: V25Theme.contentWidth)
            .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
        .scrollIndicators(.hidden)
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
                .foregroundStyle(theme.vermilion)
            Text(title)
                .font(theme.display(27, relativeTo: .title2))
            Text(detail)
                .font(.body)
                .foregroundStyle(theme.indigo.opacity(0.68))
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

    let text: String

    var body: some View {
        Label(text, systemImage: "lock.fill")
            .font(theme.utility(9))
            .tracking(0.7)
            .foregroundStyle(theme.indigo.opacity(0.58))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .accessibilityElement(children: .combine)
    }
}

struct V25PrimaryButtonStyle: ButtonStyle {
    @Environment(AppTheme.self) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline.weight(.black))
            .foregroundStyle(theme.paper)
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity, minHeight: V25Theme.controlHeight)
            .background(theme.indigo)
            .overlay { Rectangle().stroke(theme.indigo, lineWidth: 2) }
            .offset(y: configuration.isPressed && !reduceMotion ? 2 : 0)
            .opacity(configuration.isPressed ? 0.75 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: configuration.isPressed)
    }
}

struct V25SecondaryButtonStyle: ButtonStyle {
    @Environment(AppTheme.self) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.bold))
            .foregroundStyle(theme.indigo)
            .padding(.horizontal, 14)
            .frame(minHeight: 44)
            .background(theme.paper)
            .overlay { Rectangle().stroke(theme.indigo, lineWidth: 1.5) }
            .offset(y: configuration.isPressed && !reduceMotion ? 2 : 0)
            .opacity(configuration.isPressed ? 0.72 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: configuration.isPressed)
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
