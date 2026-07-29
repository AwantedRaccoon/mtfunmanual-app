import SwiftUI

struct PortableRestorePlanRequestIdentity:
    Equatable, Sendable {
    let requestID: UUID
    let packageRootDigest: String
    let mode: PortableImportMode

    func accepts(
        requestID: UUID?,
        packageRootDigest: String?,
        mode: PortableImportMode,
        plan: PortableImportPlan
    ) -> Bool {
        self.requestID == requestID
            && self.packageRootDigest
                == packageRootDigest
            && self.mode == mode
            && plan.packageRootDigest
                == self.packageRootDigest
            && plan.mode == self.mode
    }
}

struct PortableRestoreAction: Sendable {
    let makePlan:
        @MainActor @Sendable (
            _ package: AuditedPortableBackup,
            _ mode: PortableImportMode
        ) async throws -> PortableImportPlan
    let confirm:
        @MainActor @Sendable (
            _ package: AuditedPortableBackup,
            _ plan: PortableImportPlan
        ) async throws -> Void
}

private struct PortableRestoreActionEnvironmentKey:
    EnvironmentKey {
    static let defaultValue: PortableRestoreAction? = nil
}

extension EnvironmentValues {
    var portableRestoreAction: PortableRestoreAction? {
        get {
            self[
                PortableRestoreActionEnvironmentKey.self
            ]
        }
        set {
            self[
                PortableRestoreActionEnvironmentKey.self
            ] = newValue
        }
    }
}

@MainActor
struct PortableRestoreStatusView: View {
    enum Kind {
        case restartRequired
        case recovery
    }

    @Environment(AppTheme.self) private var theme
    let kind: Kind

    var body: some View {
        ZStack {
            theme.rice.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("DATA / RESTORE")
                        .font(.caption.weight(.black))
                        .tracking(2)
                        .foregroundStyle(
                            theme.vermilionText
                        )
                    Text(title)
                        .font(.system(
                            size: 34,
                            weight: .black,
                            design: .serif
                        ))
                        .foregroundStyle(
                            theme.indigoDeep
                        )
                    Text(detail)
                        .font(.body)
                        .foregroundStyle(
                            theme.secondaryText
                        )
                        .fixedSize(
                            horizontal: false,
                            vertical: true
                        )
                    Text(
                        "原资料库与导入 package 会保留到冷启动核对完成；App 不会把半成品设为当前资料库。"
                    )
                    .font(.caption)
                    .foregroundStyle(
                        theme.secondaryText
                    )
                    .fixedSize(
                        horizontal: false,
                        vertical: true
                    )
                }
                .padding(24)
                .frame(
                    maxWidth: 560,
                    alignment: .leading
                )
            }
            .scrollIndicators(.hidden)
        }
        .accessibilityIdentifier(
            "portableRestore." + identifier
        )
    }

    private var title: String {
        switch kind {
        case .restartRequired:
            "请重新打开 App"
        case .recovery:
            "恢复需要继续检查"
        }
    }

    private var detail: String {
        switch kind {
        case .restartRequired:
            "导入内容已在独立位置完成构造和校验。完全退出并重新打开 App 后，系统会再次核对，再切换到新的资料库。"
        case .recovery:
            "App 已停止继续处理，避免把不完整或已改变的 package 当作恢复成功。完全退出并重新打开后，会从受控记录继续核对。"
        }
    }

    private var identifier: String {
        switch kind {
        case .restartRequired:
            "restartRequired"
        case .recovery:
            "recovery"
        }
    }
}
