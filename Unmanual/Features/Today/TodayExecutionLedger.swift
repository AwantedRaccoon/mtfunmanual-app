import SwiftUI

@MainActor
struct TodayExecutionLedger: View {
    @Environment(AppTheme.self) private var theme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let snapshot: TodayExecutionSnapshot
    let isLoading: Bool
    let errorMessage: String?
    let inFlightOccurrenceKeys: Set<String>
    let runtimeReminderErrorCode: String?
    let retryAction: () -> Void
    let createPlanAction: () -> Void
    let administrationAction: (TodayExecutionItemSnapshot, AdministrationStatus) -> Void
    let snoozeAction: (TodayExecutionItemSnapshot) -> Void
    let reminderAction: (TodayExecutionItemSnapshot) -> Void
    let correctionAction: (TodayExecutionItemSnapshot) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            heading

            if isLoading {
                loadingState
            } else if let errorMessage {
                errorState(errorMessage)
            } else if snapshot.items.isEmpty {
                emptyState
                coverageLine
            } else {
                if !snapshot.reviewIssues.isEmpty {
                    reviewIssueBanner
                }
                coverageLine
                ForEach(Array(snapshot.items.enumerated()), id: \.element.id) { index, item in
                    itemRow(item, position: index + 1)
                }
            }
        }
        .padding(.top, 24)
        .padding(.bottom, 8)
        .accessibilityIdentifier("today.execution.ledger")
    }

    private var heading: some View {
        HStack(alignment: .lastTextBaseline) {
            Text("今日执行台账")
                .font(.headline.weight(.black))
            Spacer()
            Text("计划 / 记录")
                .font(theme.utility(10))
                .foregroundStyle(theme.secondaryText)
        }
        .padding(.vertical, 9)
        .overlay(alignment: .bottom) {
            Rectangle().fill(theme.indigo).frame(height: 2)
        }
    }

    private var loadingState: some View {
        HStack(spacing: 12) {
            ProgressView()
            Text("正在读取今天的计划…")
                .font(.subheadline.weight(.semibold))
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 72, alignment: .leading)
        .background(theme.paper)
        .accessibilityIdentifier("today.execution.loading")
    }

    private func errorState(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("今天的执行台账暂时无法读取")
                .font(.headline.weight(.black))
            Text(message)
                .font(.subheadline)
                .foregroundStyle(theme.secondaryText)
            Button("重新读取", action: retryAction)
                .font(.body.weight(.black))
                .frame(minWidth: 120, minHeight: 48)
                .foregroundStyle(theme.paper)
                .background(theme.indigo)
                .buttonStyle(V25PressStyle())
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.paper)
        .overlay { Rectangle().stroke(theme.vermilion, lineWidth: 1.5) }
        .accessibilityIdentifier("today.execution.error")
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(snapshot.reviewIssues.isEmpty ? "今天没有已建立的执行时间" : "计划中有时间需要复核")
                .font(.headline.weight(.black))
            Text(
                snapshot.reviewIssues.isEmpty
                    ? "可以在方案里为每个项目设置每天、每周、间隔天数或一次执行。"
                    : "有一项时间无法安全解释，今天不会自动生成可执行记录。请回到方案检查。"
            )
            .font(.subheadline)
            .foregroundStyle(theme.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
            Button(
                snapshot.reviewIssues.isEmpty ? "去方案建立执行时间" : "去方案检查执行时间",
                action: createPlanAction
            )
                .font(.body.weight(.black))
                .frame(maxWidth: .infinity, minHeight: 52)
                .foregroundStyle(theme.paper)
                .background(theme.indigo)
                .buttonStyle(V25PressStyle())
                .accessibilityIdentifier("today.execution.createPlan")
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.paper)
        .overlay { Rectangle().stroke(theme.indigo, lineWidth: 1.5) }
        .accessibilityIdentifier("today.execution.empty")
    }

    private var reviewIssueBanner: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("计划中有时间需要复核")
                .font(.subheadline.weight(.black))
            Text("无法安全解释的时间不会出现在台账或本地提醒中。已有的安全项目仍可继续记录。")
                .font(.caption)
                .foregroundStyle(theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            Button("去方案检查执行时间", action: createPlanAction)
                .font(.subheadline.weight(.black))
                .frame(maxWidth: .infinity, minHeight: 48)
                .foregroundStyle(theme.paper)
                .background(theme.vermilion)
                .buttonStyle(V25PressStyle())
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.rose.opacity(0.18))
        .overlay { Rectangle().stroke(theme.vermilion, lineWidth: 1.5) }
        .accessibilityIdentifier("today.execution.reviewIssues")
    }

    private var coverageLine: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: coverageSymbol)
                .frame(width: 20, height: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(coverageTitle)
                    .font(.caption.weight(.black))
                Text("系统可能受专注模式或摘要影响；这里显示的是安排覆盖，不保证投递。")
                    .font(.caption2)
                    .foregroundStyle(theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.mustard.opacity(0.14))
        .accessibilityIdentifier("today.execution.coverage")
    }

    private func itemRow(
        _ item: TodayExecutionItemSnapshot,
        position: Int
    ) -> some View {
        let isBusy = inFlightOccurrenceKeys.contains(item.id)
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Text(String(format: "%02d", position))
                    .font(theme.utility(12))
                    .foregroundStyle(theme.secondaryText)
                    .frame(width: 26, alignment: .leading)

                VStack(alignment: .leading, spacing: 4) {
                    Text(item.occurrence.displayName)
                        .font(.body.weight(.black))
                    Text(item.occurrence.localTime.unmanualClockText)
                        .font(theme.utility(13))
                        .monospacedDigit()
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Text(stateLabel(item))
                    .font(.caption.weight(.black))
                    .foregroundStyle(theme.secondaryText)
                    .multilineTextAlignment(.trailing)
            }

            if let snoozedUntil = item.snoozedUntil, item.state == .unrecorded {
                Label(
                    "稍后提醒：\(snoozedUntil.formatted(date: .omitted, time: .shortened))",
                    systemImage: "clock.badge"
                )
                .font(.caption.weight(.semibold))
                .foregroundStyle(theme.secondaryText)
            }

            if isBusy {
                Label("正在保存这条记录…", systemImage: "arrow.triangle.2.circlepath")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(theme.indigoDeep)
                    .accessibilityIdentifier("today.execution.saving.\(item.id)")
            }

            if item.state == .unrecorded {
                executionButtons(item)
            } else {
                Button("修改记录") { correctionAction(item) }
                    .font(.subheadline.weight(.black))
                    .frame(maxWidth: .infinity, minHeight: 48)
                    .foregroundStyle(theme.indigoDeep)
                    .background(theme.blue.opacity(0.16))
                    .overlay { Rectangle().stroke(theme.indigo, lineWidth: 1.5) }
                    .buttonStyle(V25PressStyle())
                    .accessibilityIdentifier("today.execution.correct.\(item.id)")
            }

            Button {
                reminderAction(item)
            } label: {
                Label(
                    item.reminderEnabled ? "关闭此计划的本地提醒" : "打开此计划的本地提醒",
                    systemImage: item.reminderEnabled ? "bell.slash" : "bell"
                )
                .font(.caption.weight(.black))
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(theme.secondaryText)
            .accessibilityIdentifier("today.execution.reminder.\(item.id)")
        }
        .padding(.vertical, 14)
        .padding(.horizontal, 12)
        .background(theme.paper)
        .overlay(alignment: .bottom) {
            Rectangle().fill(theme.indigo.opacity(0.36)).frame(height: 1)
        }
        .disabled(isBusy)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private func executionButtons(_ item: TodayExecutionItemSnapshot) -> some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(spacing: 8) {
                administrationButton("已使用", item: item, status: .taken, primary: true)
                snoozeButton(item)
                administrationButton("本次跳过", item: item, status: .skipped, primary: false)
            }
        } else {
            HStack(spacing: 8) {
                administrationButton("已使用", item: item, status: .taken, primary: true)
                snoozeButton(item)
                administrationButton("本次跳过", item: item, status: .skipped, primary: false)
            }
        }
    }

    private func administrationButton(
        _ title: String,
        item: TodayExecutionItemSnapshot,
        status: AdministrationStatus,
        primary: Bool
    ) -> some View {
        Button(title) { administrationAction(item, status) }
            .font(.caption.weight(.black))
            .frame(maxWidth: .infinity, minHeight: 48)
            .foregroundStyle(primary ? theme.paper : theme.indigoDeep)
            .background(primary ? theme.indigo : theme.paper)
            .overlay { Rectangle().stroke(theme.indigo, lineWidth: 1.5) }
            .buttonStyle(V25PressStyle())
            .accessibilityIdentifier("today.execution.\(status.rawValue).\(item.id)")
    }

    private func snoozeButton(_ item: TodayExecutionItemSnapshot) -> some View {
        Button(
            item.reminderEnabled ? "稍后 \(item.defaultSnoozeMinutes) 分钟" : "先打开提醒"
        ) {
            if item.reminderEnabled {
                snoozeAction(item)
            } else {
                reminderAction(item)
            }
        }
            .font(.caption.weight(.black))
            .frame(maxWidth: .infinity, minHeight: 48)
            .foregroundStyle(theme.indigoDeep)
            .background(theme.mustard.opacity(0.22))
            .overlay { Rectangle().stroke(theme.indigo, lineWidth: 1.5) }
            .buttonStyle(V25PressStyle())
            .accessibilityIdentifier(
                item.reminderEnabled
                    ? "today.execution.snooze.\(item.id)"
                    : "today.execution.enableReminder.\(item.id)"
            )
    }

    private func stateLabel(_ item: TodayExecutionItemSnapshot) -> String {
        switch item.state {
        case .unrecorded: "未记录"
        case .taken: "已使用"
        case .skipped: "本次跳过"
        }
    }

    private var coverageTitle: String {
        TodayReminderCoveragePresentation.title(
            coverage: snapshot.coverage,
            runtimeErrorCode: runtimeReminderErrorCode
        )
    }

    private var coverageSymbol: String {
        if runtimeReminderErrorCode != nil {
            return "bell.slash"
        }
        return switch snapshot.coverage.status {
        case .scheduledForWindow: "bell.badge"
        case .limitedByBudget: "bell.badge.fill"
        case .blockedByPermission, .limitedBySystemSettings, .schedulingFailed: "bell.slash"
        default: "bell"
        }
    }
}

enum TodayReminderCoveragePresentation {
    static func title(
        coverage: NotificationCoverageSnapshot,
        runtimeErrorCode: String?
    ) -> String {
        if runtimeErrorCode != nil {
            return "部分提醒尚未安排，请打开 App 重试"
        }
        switch coverage.status {
        case .disabledByUser: return "本地提醒未开启"
        case .notDetermined: return "等待你确认系统通知权限"
        case .blockedByPermission: return "系统通知已关闭，可在系统设置中修改"
        case .limitedBySystemSettings: return "系统当前不会显示提醒横幅"
        case .reconciliationPending: return "正在核对本地提醒"
        case .scheduledForWindow:
            if let date = coverage.scheduledThrough {
                return "已安排至 \(date.formatted(date: .abbreviated, time: .shortened))"
            }
            return "当前窗口没有待安排的提醒"
        case .limitedByBudget:
            if let date = coverage.scheduledThrough {
                return "系统容量有限，连续覆盖至 \(date.formatted(date: .abbreviated, time: .shortened)) 之前"
            }
            return "系统容量有限，当前无法建立连续覆盖"
        case .schedulingFailed: return "部分提醒尚未安排，请打开 App 重试"
        case .staleObservation: return "提醒覆盖等待重新核对"
        }
    }
}

private extension HistoricalLocalTime {
    var unmanualClockText: String {
        String(format: "%02d:%02d", hour, minute)
    }
}
