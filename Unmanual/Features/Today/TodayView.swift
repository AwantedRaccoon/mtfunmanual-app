import SwiftUI
import UIKit

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
    @State private var actionGate = TodayExecutionActionGate()
    @State private var contentRefreshGate = TodayLatestRequestGate()
    @State private var executionRefreshGate = TodayLatestRequestGate()

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
                inFlightOccurrenceKeys: actionGate.inFlightOccurrenceKeys,
                runtimeReminderErrorCode: reminderRuntime?.lastErrorCode,
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
        .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged)) { _ in
            Task { await refresh() }
        }
        .onReceive(
            NotificationCenter.default.publisher(for: UIApplication.significantTimeChangeNotification)
        ) { _ in
            Task { await refresh() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .NSSystemTimeZoneDidChange)) { _ in
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
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .localSaveErrorAlert(message: $actionErrorMessage)
    }

    private func refreshAfterDismiss() {
        Task { await refresh() }
    }

    private func refresh() async {
        let request = contentRefreshGate.begin()
        guard let appReadActor else {
            await refreshExecution()
            return
        }
        let now = Date()
        let displayTimeZoneIdentifier = TimeZone.autoupdatingCurrent.identifier
        if let updated = try? await appReadActor.todaySnapshot() {
            guard contentRefreshGate.isCurrent(request) else { return }
            snapshot = updated
        }
        if let today = try? HistoricalTimestamp.captured(
            instant: now,
            timeZoneIdentifier: displayTimeZoneIdentifier
        ).localDate,
        let updated = try? await appReadActor.coreRegimenOverview(asOf: today) {
            guard contentRefreshGate.isCurrent(request) else { return }
            coreRegimenOverview = updated
        }
        guard contentRefreshGate.isCurrent(request) else { return }
        await refreshExecution()
    }

    private func refreshExecution() async {
        let request = executionRefreshGate.begin()
        guard let appReadActor else {
            if executionRefreshGate.isCurrent(request) {
                executionIsLoading = false
                executionErrorMessage = "本地资料尚未准备好，请稍后重试。"
            }
            return
        }
        executionIsLoading = true
        defer {
            if executionRefreshGate.isCurrent(request) {
                executionIsLoading = false
            }
        }
        do {
            let updated = try await appReadActor.todayExecutionSnapshot(
                now: Date(),
                displayTimeZoneIdentifier: TimeZone.autoupdatingCurrent.identifier
            )
            guard executionRefreshGate.isCurrent(request) else { return }
            executionSnapshot = updated
            executionErrorMessage = nil
        } catch {
            guard executionRefreshGate.isCurrent(request) else { return }
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
        let committedAt = Date()
        let displayTimeZoneIdentifier = TimeZone.autoupdatingCurrent.identifier
        guard actionGate.begin(occurrenceKey: item.id) else { return }
        Task {
            defer { actionGate.finish(occurrenceKey: item.id) }
            do {
                let actual = try HistoricalTimestamp.captured(
                    instant: actualDate,
                    timeZoneIdentifier: displayTimeZoneIdentifier,
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
                        committedAt: committedAt,
                        displayTimeZoneIdentifier: displayTimeZoneIdentifier
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
        guard actionGate.begin(occurrenceKey: item.id) else { return }
        let now = Date()
        let displayTimeZoneIdentifier = TimeZone.autoupdatingCurrent.identifier
        Task {
            defer { actionGate.finish(occurrenceKey: item.id) }
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
                        committedAt: now,
                        displayTimeZoneIdentifier: displayTimeZoneIdentifier
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
        guard actionGate.begin(occurrenceKey: item.id) else { return }
        Task {
            defer { actionGate.finish(occurrenceKey: item.id) }
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

struct TodayExecutionActionGate: Equatable {
    private(set) var inFlightOccurrenceKeys: Set<String> = []

    mutating func begin(occurrenceKey: String) -> Bool {
        inFlightOccurrenceKeys.insert(occurrenceKey).inserted
    }

    mutating func finish(occurrenceKey: String) {
        inFlightOccurrenceKeys.remove(occurrenceKey)
    }
}

struct TodayLatestRequestGate: Equatable {
    private var latestRequest = 0

    mutating func begin() -> Int {
        latestRequest += 1
        return latestRequest
    }

    func isCurrent(_ request: Int) -> Bool {
        request == latestRequest
    }
}

private enum TodaySheet: String, Identifiable {
    case startDate
    case countdown
    case quickRecord

    var id: String { rawValue }
}
