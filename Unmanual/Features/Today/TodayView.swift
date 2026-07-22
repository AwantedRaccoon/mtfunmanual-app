import SwiftUI

@MainActor
struct TodayView: View {
    @Environment(\.appReadActor) private var appReadActor
    @Environment(\.appDataWriter) private var appDataWriter
    @Environment(\.localReminderRuntime) private var reminderRuntime

    @Binding var selectedTab: AppTab
    @State private var presentedSheet: TodaySheet?
    @State private var snapshot = TodaySnapshot.empty
    @State private var coreRegimenOverview = CoreRegimenOverviewSnapshot.empty
    @State private var executionSnapshot = TodayExecutionSnapshot.empty
    @State private var executionIsLoading = true
    @State private var executionErrorMessage: String?
    @State private var actionErrorMessage: String?
    @State private var reminderPromptItem: TodayExecutionItemSnapshot?
    @State private var correctionItem: TodayExecutionItemSnapshot?

    var body: some View {
        V25Page {
            V25TodayHome(
                profile: snapshot.profile,
                countdown: snapshot.countdown,
                regimens: coreRegimenOverview.current.map { [$0] } ?? [],
                records: snapshot.labRecords,
                entries: snapshot.entries,
                quickRecordAction: { presentedSheet = .quickRecord },
                startDateAction: { presentedSheet = .startDate },
                countdownAction: { presentedSheet = .countdown },
                regimenAction: { selectedTab = .regimen },
                metricsAction: { selectedTab = .journey },
                journeyAction: { selectedTab = .journey },
                executionSnapshot: executionSnapshot,
                executionIsLoading: executionIsLoading,
                executionErrorMessage: executionErrorMessage,
                executionRetryAction: { Task { await refreshExecution() } },
                administrationAction: { item, status in
                    commitAdministration(item, status)
                },
                snoozeAction: snooze,
                reminderAction: handleReminder,
                correctionAction: { correctionItem = $0 }
            )
        }
        .navigationBarHidden(true)
        .task { await refresh() }
        .onReceive(NotificationCenter.default.publisher(for: .unmanualLocalDataChanged)) { _ in
            Task { await refresh() }
        }
        .sheet(item: $presentedSheet, onDismiss: refreshAfterDismiss) { destination in
            switch destination {
            case .startDate:
                StartDateEditor()
            case .countdown:
                CountdownEditor()
            case .quickRecord:
                QuickRecordEditor()
            }
        }
        .sheet(item: $reminderPromptItem) { item in
            LocalReminderConsentSheet(
                item: item,
                cancel: { reminderPromptItem = nil },
                confirm: { enableReminder(for: item) }
            )
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .sheet(item: $correctionItem) { item in
            TodayExecutionCorrectionSheet(
                item: item,
                cancel: { correctionItem = nil },
                save: { status, actualDate in
                    correctionItem = nil
                    commitAdministration(item, status, actualDate: actualDate)
                }
            )
            .presentationDetents([.medium])
            .presentationDragIndicator(.visible)
        }
        .localSaveErrorAlert(message: $actionErrorMessage)
    }

    private func refreshAfterDismiss() {
        Task { await refresh() }
    }

    private func refresh() async {
        guard let appReadActor else { return }
        if let updated = try? await appReadActor.todaySnapshot() {
            snapshot = updated
        }
        if let today = try? HistoricalTimestamp.captured(
            instant: Date(),
            timeZoneIdentifier: TimeZone.autoupdatingCurrent.identifier
        ).localDate,
        let updated = try? await appReadActor.coreRegimenOverview(asOf: today) {
            coreRegimenOverview = updated
        }
        await refreshExecution()
    }

    private func refreshExecution() async {
        guard let appReadActor else {
            executionIsLoading = false
            executionErrorMessage = "本地资料尚未准备好，请稍后重试。"
            return
        }
        executionIsLoading = true
        defer { executionIsLoading = false }
        do {
            executionSnapshot = try await appReadActor.todayExecutionSnapshot(
                now: Date(),
                displayTimeZoneIdentifier: TimeZone.autoupdatingCurrent.identifier
            )
            executionErrorMessage = nil
        } catch {
            executionErrorMessage = "原资料没有被修改。你可以重新读取，或到方案检查执行时间。"
        }
    }

    private func commitAdministration(
        _ item: TodayExecutionItemSnapshot,
        _ status: AdministrationStatus,
        actualDate: Date = Date()
    ) {
        guard let appDataWriter else {
            actionErrorMessage = "本地资料尚未准备好，请稍后再试。"
            return
        }
        Task {
            do {
                let actual = try HistoricalTimestamp.captured(
                    instant: actualDate,
                    timeZoneIdentifier: TimeZone.autoupdatingCurrent.identifier,
                    precision: .minute,
                    provenance: .userEntered
                )
                _ = try await appDataWriter.commitAdministration(
                    CommitAdministrationCommand(
                        operationID: UUID(),
                        eventID: UUID(),
                        occurrence: item.occurrence,
                        expectedLeafEventID: item.effectiveEventID,
                        status: status,
                        actualTimestamp: actual,
                        committedAt: Date()
                    )
                )
                await refreshExecutionAndReminders()
            } catch {
                actionErrorMessage = "记录没有保存。台账可能已经变化，请重新读取后再试。"
                await refreshExecution()
            }
        }
    }

    private func snooze(_ item: TodayExecutionItemSnapshot) {
        guard let appDataWriter else {
            actionErrorMessage = "本地资料尚未准备好，请稍后再试。"
            return
        }
        let now = Date()
        Task {
            do {
                _ = try await appDataWriter.applyReminderOverride(
                    ApplyReminderOverrideCommand(
                        operationID: UUID(),
                        overrideID: UUID(),
                        occurrence: item.occurrence,
                        expectedOverrideID: item.effectiveOverrideID,
                        fireAt: now.addingTimeInterval(
                            TimeInterval(item.defaultSnoozeMinutes * 60)
                        ),
                        committedAt: now
                    )
                )
                await refreshExecutionAndReminders()
            } catch {
                actionErrorMessage = "稍后提醒没有保存。原执行记录没有被修改。"
                await refreshExecution()
            }
        }
    }

    private func handleReminder(_ item: TodayExecutionItemSnapshot) {
        if item.reminderEnabled {
            setReminderEnabled(false, for: item, requestAuthorization: false)
        } else {
            reminderPromptItem = item
        }
    }

    private func enableReminder(for item: TodayExecutionItemSnapshot) {
        reminderPromptItem = nil
        setReminderEnabled(true, for: item, requestAuthorization: true)
    }

    private func setReminderEnabled(
        _ isEnabled: Bool,
        for item: TodayExecutionItemSnapshot,
        requestAuthorization: Bool
    ) {
        guard let appDataWriter else {
            actionErrorMessage = "本地资料尚未准备好，请稍后再试。"
            return
        }
        Task {
            do {
                _ = try await appDataWriter.setReminderPreference(
                    SetReminderPreferenceCommand(
                        operationID: UUID(),
                        scheduleRuleID: item.occurrence.scheduleRuleID,
                        expectedRuleRevision: item.occurrence.scheduleRevision,
                        isEnabled: isEnabled,
                        defaultSnoozeMinutes: item.defaultSnoozeMinutes,
                        committedAt: Date()
                    )
                )
                if let appReadActor, let reminderRuntime {
                    if requestAuthorization {
                        await reminderRuntime.requestAuthorizationAndReconcile(
                            reader: appReadActor,
                            writer: appDataWriter
                        )
                    } else {
                        await reminderRuntime.reconcile(
                            reader: appReadActor,
                            writer: appDataWriter
                        )
                    }
                }
                await refreshExecution()
            } catch {
                actionErrorMessage = "提醒设置没有保存。计划和执行记录没有被修改。"
                await refreshExecution()
            }
        }
    }

    private func refreshExecutionAndReminders() async {
        if let appReadActor, let appDataWriter, let reminderRuntime {
            await reminderRuntime.reconcile(
                reader: appReadActor,
                writer: appDataWriter
            )
        }
        await refreshExecution()
    }
}

private enum TodaySheet: String, Identifiable {
    case startDate
    case countdown
    case quickRecord

    var id: String { rawValue }
}
