import SwiftUI

@MainActor
struct LocalReminderConsentSheet: View {
    @Environment(AppTheme.self) private var theme

    let item: TodayExecutionItemSnapshot
    let cancel: () -> Void
    let confirm: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Button("取消", action: cancel)
                    .frame(minWidth: 44, minHeight: 44, alignment: .leading)
                Spacer()
                Text("LOCAL / REMINDER")
                    .font(theme.utility(10))
                    .tracking(0.8)
            }
            .overlay(alignment: .bottom) {
                Rectangle().fill(theme.indigo).frame(height: 1)
            }

            Text("打开本地提醒？")
                .font(theme.display(30))
                .foregroundStyle(theme.indigoDeep)

            Text(
                "系统会询问通知权限。"
                    + SystemBackupDisclosure.compact
                    + "关闭通知权限也不会删除你的计划。"
            )
                .font(.body)
                .foregroundStyle(theme.indigo.opacity(0.72))
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 7) {
                Text("锁屏预览示例")
                    .font(.caption.weight(.black))
                    .foregroundStyle(theme.vermilion)
                Text("给自己留一点时间")
                    .font(.headline.weight(.black))
                Text("打开 App 查看今天的安排。")
                    .font(.subheadline)
                Text("不会显示 HRT、药名、剂量或身份信息。")
                    .font(.caption)
                    .foregroundStyle(theme.indigo.opacity(0.64))
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(theme.paper)
            .overlay { Rectangle().stroke(theme.indigo, lineWidth: 1.5) }

            Text("此设置会应用到“\(item.occurrence.displayName)”这条计划的未来时间。")
                .font(.caption)
                .foregroundStyle(theme.indigo.opacity(0.68))

            Spacer(minLength: 0)

            Button("继续并请求系统权限", action: confirm)
                .buttonStyle(V25PrimaryButtonStyle())
                .accessibilityIdentifier("today.execution.reminder.confirm")
        }
        .padding(V25Theme.pagePadding)
        .foregroundStyle(theme.indigoDeep)
        .background(theme.rice.ignoresSafeArea())
    }
}

@MainActor
struct TodayExecutionCorrectionSheet: View {
    @Environment(AppTheme.self) private var theme

    let item: TodayExecutionItemSnapshot
    let cancel: () -> Void
    let save: (AdministrationStatus, Date) -> Void

    @State private var status: AdministrationStatus
    @State private var actualDate: Date

    init(
        item: TodayExecutionItemSnapshot,
        cancel: @escaping () -> Void,
        save: @escaping (AdministrationStatus, Date) -> Void
    ) {
        self.item = item
        self.cancel = cancel
        self.save = save
        let initialStatus: AdministrationStatus = switch item.state {
        case .taken: .taken
        case .skipped: .skipped
        case .unrecorded: .taken
        }
        _status = State(initialValue: initialStatus)
        _actualDate = State(initialValue: item.actualTimestamp?.instant ?? Date())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Button("取消", action: cancel)
                    .frame(minWidth: 44, minHeight: 44, alignment: .leading)
                Spacer()
                Text("CORRECTION / 追加纠错")
                    .font(theme.utility(10))
            }
            .overlay(alignment: .bottom) {
                Rectangle().fill(theme.indigo).frame(height: 1)
            }

            Text("修改执行记录")
                .font(theme.display(28))
            Text(item.occurrence.displayName)
                .font(.headline.weight(.black))
                .foregroundStyle(theme.vermilion)

            Picker("记录状态", selection: $status) {
                Text("已使用").tag(AdministrationStatus.taken)
                Text("本次跳过").tag(AdministrationStatus.skipped)
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("today.execution.correction.status")

            VStack(alignment: .leading, spacing: 8) {
                Text("实际时间")
                    .font(.caption.weight(.black))
                DatePicker(
                    "实际时间",
                    selection: $actualDate,
                    displayedComponents: [.date, .hourAndMinute]
                )
                .labelsHidden()
                .accessibilityLabel("实际时间")
                .accessibilityIdentifier("today.execution.correction.time")
            }

            Text("旧记录会保留；这次修改会追加为新的有效记录。")
                .font(.caption)
                .foregroundStyle(theme.indigo.opacity(0.68))

            Spacer(minLength: 0)

            Button("保存修改") { save(status, actualDate) }
                .buttonStyle(V25PrimaryButtonStyle())
                .accessibilityIdentifier("today.execution.correction.save")
        }
        .padding(V25Theme.pagePadding)
        .foregroundStyle(theme.indigoDeep)
        .background(theme.rice.ignoresSafeArea())
    }
}
