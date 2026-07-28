import SwiftUI

@MainActor
struct AppPrivacySessionRoot<Content: View>: View {
    @Environment(AppTheme.self) private var theme

    let session: AppDataSession
    let coordinator: AppPrivacyCoordinator
    @ViewBuilder let sensitiveContent: () -> Content

    var body: some View {
        Group {
            if coordinator.permitsSensitiveRoot(
                for: session.store.generationID
            ) {
                sensitiveContent()
            } else {
                AppLockGateView(coordinator: coordinator)
            }
        }
        .background(theme.rice)
        .task(id: session.store.generationID) {
            await coordinator.bind(
                reader: session.reader,
                generationID: session.store.generationID
            )
        }
        .onDisappear {
            coordinator.invalidate(
                generationID: session.store.generationID
            )
        }
    }
}

@MainActor
struct AppLockGateView: View {
    @Environment(AppTheme.self) private var theme
    let coordinator: AppPrivacyCoordinator

    var body: some View {
        ZStack {
            theme.rice.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Text("LOCAL / PRIVATE")
                        .font(theme.utility(11))
                        .tracking(1.4)
                        .foregroundStyle(theme.mustardText)
                    Text(title)
                        .font(theme.display(38))
                        .foregroundStyle(theme.indigoDeep)
                        .padding(.top, 12)
                    Rectangle()
                        .fill(theme.indigo)
                        .frame(height: 2)
                        .padding(.vertical, 20)
                    Text(detail)
                        .font(.body)
                        .foregroundStyle(theme.indigoDeep)
                        .fixedSize(horizontal: false, vertical: true)

                    if canUnlock {
                        Button {
                            Task { await coordinator.unlock() }
                        } label: {
                            HStack {
                                Text("解锁本地资料")
                                    .font(.body.weight(.black))
                                Spacer()
                                Image(systemName: "lock.open")
                            }
                            .foregroundStyle(theme.paper)
                            .padding(.horizontal, 16)
                            .frame(
                                maxWidth: .infinity,
                                minHeight: 52
                            )
                            .background(theme.indigo)
                            .overlay(alignment: .bottomTrailing) {
                                Rectangle()
                                    .fill(theme.mustard)
                                    .frame(width: 44, height: 4)
                            }
                        }
                        .buttonStyle(V25PressStyle())
                        .padding(.top, 24)
                        .accessibilityIdentifier("privacy.unlock")
                    } else if isAuthenticating {
                        HStack(spacing: 12) {
                            ProgressView()
                            Text("正在等待设备认证")
                                .font(.body.weight(.bold))
                        }
                        .frame(minHeight: 52)
                        .padding(.top, 24)
                        .accessibilityIdentifier(
                            "privacy.authenticating"
                        )
                    }

                    Text(
                        "App Lock 不会删除记录、阻止系统备份，"
                            + "也不能防止你主动导出的文件离开 App。"
                    )
                    .font(.caption)
                    .foregroundStyle(theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 18)
                }
                .padding(24)
                .frame(maxWidth: 520, alignment: .leading)
            }
        }
        .accessibilityIdentifier("privacy.gate")
    }

    private var title: String {
        switch coordinator.gateState {
        case .bootstrapping:
            return "正在核对本地保护"
        case .unavailable:
            return "本地资料暂时不可打开"
        default:
            return "本地资料已锁定"
        }
    }

    private var detail: String {
        switch coordinator.gateState {
        case .bootstrapping:
            return "先确认这台设备上的隐私设置，再打开个人记录。"
        case let .locked(message):
            return message
                ?? "使用 Face ID、Touch ID 或设备密码继续。"
        case let .unavailable(message):
            return message
        default:
            return "使用 Face ID、Touch ID 或设备密码继续。"
        }
    }

    private var canUnlock: Bool {
        if case .locked = coordinator.gateState {
            return true
        }
        return false
    }

    private var isAuthenticating: Bool {
        if case .authenticating = coordinator.gateState {
            return true
        }
        return false
    }
}

@MainActor
struct ScenePrivacyShieldContainer<Content: View>: View {
    let isActive: Bool
    @ViewBuilder let content: () -> Content

    var body: some View {
        ZStack {
            content()
                .allowsHitTesting(isActive)
                .accessibilityHidden(!isActive)
            if !isActive {
                RecentTasksPrivacyShield()
                    .zIndex(10_000)
            }
        }
        .transaction { transaction in
            transaction.animation = nil
            transaction.disablesAnimations = true
        }
    }
}

@MainActor
struct RecentTasksPrivacyShield: View {
    @Environment(AppTheme.self) private var theme

    var body: some View {
        ZStack {
            theme.indigoDeep.ignoresSafeArea()
            VStack(spacing: 12) {
                Rectangle()
                    .fill(theme.mustard)
                    .frame(width: 54, height: 4)
                Text("不全书")
                    .font(theme.display(30))
                    .foregroundStyle(theme.paper)
                Text("本地资料已遮挡")
                    .font(theme.utility(11))
                    .tracking(1.2)
                    .foregroundStyle(theme.mustard)
            }
            .accessibilityElement(children: .combine)
        }
        .accessibilityIdentifier("privacy.sceneShield")
    }
}
