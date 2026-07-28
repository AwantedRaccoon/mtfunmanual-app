import SwiftUI

@MainActor
struct OnboardingReminderSetupView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appDataWriter) private var appDataWriter
    @Environment(\.appReadActor) private var appReadActor
    @Environment(\.appDataControlCoordinator)
    private var appDataControlCoordinator
    @Environment(\.localReminderRuntime) private var reminderRuntime
    @Environment(AppTheme.self) private var theme

    @State private var options: [OnboardingReminderOption]
    @State private var coverage: NotificationCoverageSnapshot
    @State private var pendingConsent: OnboardingReminderOption?
    @State private var inFlightIDs: Set<UUID> = []
    @State private var errorMessage: String?

    init(
        options: [OnboardingReminderOption],
        coverage: NotificationCoverageSnapshot
    ) {
        _options = State(initialValue: options)
        _coverage = State(initialValue: coverage)
    }

    private var canDismiss: Bool {
        EditorWriteDismissalPolicy.allowsDismiss(
            isWriting: !inFlightIDs.isEmpty
        )
    }

    var body: some View {
        NavigationStack {
            V25EditorPage(
                register: "LOCAL / REMINDER",
                eyebrow: "OPTIONAL STEP",
                title: "选择本地提醒",
                detail: "提醒只应用到你主动打开的计划时段。系统权限会在确认后再询问。",
                isCancelEnabled: canDismiss,
                cancel: {
                    guard canDismiss else { return }
                    dismiss()
                }
            ) {
                if options.isEmpty {
                    emptyState
                } else {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(options) { option in
                            reminderRow(option)
                        }
                    }
                }

                V25PrivacyFooter(
                    text:
                        "锁屏只显示中性措辞，不显示 HRT、药名、剂量或身份信息。拒绝系统权限不会删除计划。"
                )
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                V25SaveBar(
                    title: "返回首次设置",
                    isEnabled: inFlightIDs.isEmpty,
                    accessibilityIdentifier:
                        "onboarding.reminder.done",
                    action: dismiss.callAsFunction
                )
            }
        }
        .tint(theme.indigo)
        .interactiveDismissDisabled(!canDismiss)
        .sheet(item: $pendingConsent) { option in
            LocalReminderConsentSheet(
                displayName: option.displayName,
                cancel: { pendingConsent = nil },
                confirm: {
                    pendingConsent = nil
                    setEnabled(
                        true,
                        option: option,
                        requestsAuthorization: true
                    )
                }
            )
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .localSaveErrorAlert(message: $errorMessage)
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("还没有可设置的时段")
                .font(.headline.weight(.black))
            Text("先封存一个含时间安排的当前方案，再回来打开提醒；也可以暂时跳过。")
                .font(.subheadline)
                .foregroundStyle(theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.paper)
        .overlay { Rectangle().stroke(theme.indigo, lineWidth: 1.5) }
        .accessibilityIdentifier("onboarding.reminder.empty")
    }

    private func reminderRow(
        _ option: OnboardingReminderOption
    ) -> some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 5) {
                Text(option.displayName)
                    .font(.headline.weight(.black))
                    .foregroundStyle(theme.indigoDeep)
                Text(option.scheduleSummary)
                    .font(.subheadline)
                    .foregroundStyle(theme.secondaryText)
                Text(
                    option.isEnabled
                        ? reminderStatusText
                        : "提醒未选择"
                )
                    .font(.caption.weight(.bold))
                    .foregroundStyle(
                        option.isEnabled
                            ? theme.mossText
                            : theme.secondaryText
                    )
                    .accessibilityIdentifier(
                        "onboarding.reminder.status."
                            + option.id.uuidString
                    )
            }
            Spacer(minLength: 8)
            Button(option.isEnabled ? "关闭" : "打开") {
                if option.isEnabled {
                    setEnabled(
                        false,
                        option: option,
                        requestsAuthorization: false
                    )
                } else {
                    pendingConsent = option
                }
            }
            .font(.body.weight(.bold))
            .frame(minWidth: 64, minHeight: 44)
            .disabled(inFlightIDs.contains(option.id))
            .accessibilityIdentifier(
                "onboarding.reminder.toggle.\(option.id.uuidString)"
            )
        }
        .padding(.vertical, 12)
        .overlay(alignment: .bottom) {
            Rectangle().fill(theme.indigo.opacity(0.65)).frame(height: 1)
        }
    }

    private func setEnabled(
        _ isEnabled: Bool,
        option: OnboardingReminderOption,
        requestsAuthorization: Bool
    ) {
        guard !inFlightIDs.contains(option.id),
              let appDataWriter,
              let appReadActor,
              let reminderRuntime else {
            errorMessage =
                "本地提醒服务尚未准备好，计划没有改变。"
            return
        }
        inFlightIDs.insert(option.id)
        Task {
            defer { inFlightIDs.remove(option.id) }
            var preferenceWasSaved = false
            do {
                _ = try await appDataWriter.setReminderPreference(
                    SetReminderPreferenceCommand(
                        operationID: UUID(),
                        scheduleRuleID: option.scheduleRuleID,
                        expectedRuleRevision:
                            option.scheduleRevision,
                        isEnabled: isEnabled,
                        defaultSnoozeMinutes:
                            option.defaultSnoozeMinutes,
                        committedAt: Date()
                    )
                )
                preferenceWasSaved = true
                if requestsAuthorization {
                    _ = await reminderRuntime
                        .requestAuthorizationAndReconcile(
                            reader: appReadActor,
                            writer: appDataWriter,
                            dataControlCoordinator:
                                appDataControlCoordinator
                        )
                } else {
                    await reminderRuntime.reconcile(
                        reader: appReadActor,
                        writer: appDataWriter,
                        dataControlCoordinator:
                            appDataControlCoordinator
                    )
                }
                let refreshed = try await appReadActor
                    .onboardingSnapshot()
                options = refreshed.reminderOptions
                coverage = refreshed.reminderCoverage
                NotificationCenter.default.post(
                    name: .unmanualLocalDataChanged,
                    object: nil
                )
            } catch {
                errorMessage = preferenceWasSaved
                    ? "提醒选择已保存，但系统状态没有重新读取；请返回后再打开此页核对。"
                    : "提醒设置没有保存；方案和其他记录没有改变。"
            }
        }
    }

    private var reminderStatusText: String {
        switch coverage.status {
        case .disabledByUser:
            "已选择，等待安排"
        case .notDetermined:
            "已选择，等待系统权限"
        case .blockedByPermission:
            "已选择，系统通知已关闭"
        case .limitedBySystemSettings:
            "已选择，系统当前不显示提醒"
        case .reconciliationPending:
            "已选择，正在核对"
        case .scheduledForWindow:
            "已选择，已安排当前窗口"
        case .limitedByBudget:
            "已选择，系统容量有限"
        case .schedulingFailed:
            "已选择，尚未安排成功"
        case .staleObservation:
            "已选择，等待重新核对"
        }
    }
}
