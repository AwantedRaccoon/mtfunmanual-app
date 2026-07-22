import SwiftUI

struct AppDataOpeningView: View {
    @Environment(AppTheme.self) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("LOCAL / OPENING")
                .font(theme.utility(10))
                .tracking(0.9)
                .foregroundStyle(theme.mustard)
            Text("正在打开本地资料")
                .font(theme.display(30, relativeTo: .title))
                .foregroundStyle(theme.paper)
            ProgressView()
                .tint(theme.mustard)
                .accessibilityLabel("正在打开本地资料")
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(theme.indigoDeep.ignoresSafeArea())
    }
}

struct RecoveryModeView: View {
    @Environment(AppTheme.self) private var theme

    let recovery: AppDataRecoveryState
    let retry: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("LOCAL / RECOVERY")
                    .font(theme.utility(10))
                    .tracking(0.9)
                    .foregroundStyle(theme.vermilion)

                Text(recovery.title)
                    .font(theme.display(36, relativeTo: .largeTitle))
                    .foregroundStyle(theme.indigoDeep)
                    .padding(.top, 12)

                Rectangle()
                    .fill(theme.indigo)
                    .frame(height: 2)
                    .padding(.top, 16)

                Text(recovery.userMessage)
                    .font(.body)
                    .foregroundStyle(theme.indigo)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 18)

                VStack(alignment: .leading, spacing: 8) {
                    Text("现在可以做什么")
                        .font(theme.utility(10))
                        .tracking(0.8)
                        .foregroundStyle(theme.mustard)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("设备解锁且空间充足后再检查。")
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.trailing, 8)
                        Text("重试不清空资料；原文件和系统备份可能不可用。\n\u{00A0}")
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.trailing, 8)
                    }
                    .font(.callout)
                    .foregroundStyle(theme.paper)
                    .lineLimit(nil)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
                    .accessibilityHidden(true)
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(theme.indigoDeep)
                .padding(.top, 22)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(
                    "现在可以做什么。设备解锁且空间充足后再检查。重试不清空资料；原文件和系统备份可能不可用。"
                )

                Button("重新检查本地资料", action: retry)
                    .buttonStyle(V25PrimaryButtonStyle())
                    .padding(.top, 22)
                    .accessibilityHint("重新尝试打开现有资料，不会删除或重建资料库")
                    .accessibilityIdentifier("recovery.retry")
            }
            .padding(24)
            .frame(maxWidth: 620)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(theme.rice.ignoresSafeArea())
    }
}
