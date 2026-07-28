import Foundation
import SwiftData

struct OnboardingProgressSnapshot: Equatable, Sendable {
    let step: OnboardingStep
    let skippedStartDate: Bool
    let skippedReminder: Bool
    let skippedCountdown: Bool
    let completedAt: Date?
    let updatedAt: Date
}

struct OnboardingDraftSnapshot: Identifiable, Equatable, Sendable {
    let id: UUID
    let title: String
    let effectiveStartDate: CivilDateFact
}

struct OnboardingReminderOption: Identifiable, Equatable, Sendable {
    var id: UUID { scheduleRuleID }

    let scheduleRuleID: UUID
    let scheduleRevision: Int
    let regimenVersionID: UUID
    let displayName: String
    let scheduleSummary: String
    let isEnabled: Bool
    let defaultSnoozeMinutes: Int
}

struct OnboardingSnapshot: Equatable, Sendable {
    let isCompleted: Bool
    let progress: OnboardingProgressSnapshot
    let profile: HRTProfileSnapshot?
    let hasEligibleRegimen: Bool
    let regimenNeedsReview: Bool
    let drafts: [OnboardingDraftSnapshot]
    let reminderOptions: [OnboardingReminderOption]
    let reminderCoverage: NotificationCoverageSnapshot
    let countdown: CountdownCurrentSnapshot?

    var hasEnabledReminder: Bool {
        reminderOptions.contains(where: \.isEnabled)
    }

    var reminderStatusText: String {
        guard hasEnabledReminder else { return "未选择提醒时段" }
        return switch reminderCoverage.status {
        case .disabledByUser:
            "已选择时段，等待安排"
        case .notDetermined:
            "已选择时段，等待系统权限"
        case .blockedByPermission:
            "已选择时段，系统通知已关闭"
        case .limitedBySystemSettings:
            "已选择时段，系统当前不显示提醒"
        case .reconciliationPending:
            "已选择时段，正在核对"
        case .scheduledForWindow:
            "已选择时段，已安排当前窗口"
        case .limitedByBudget:
            "已选择时段，系统容量有限"
        case .schedulingFailed:
            "已选择时段，尚未安排成功"
        case .staleObservation:
            "已选择时段，等待重新核对"
        }
    }
}

extension AppReadActor {
    func onboardingSnapshot(
        asOf instant: Date = Date(),
        displayTimeZoneIdentifier: String =
            TimeZone.autoupdatingCurrent.identifier,
        terminalOverlay: DataControlTerminalOverlay = .empty
    ) throws -> OnboardingSnapshot {
#if DEBUG
        if ProcessInfo.processInfo.arguments.contains(
            "-unmanual-onboarding-read-error"
        ) {
            throw AppDataFailure.corruptionSuspected
        }
#endif
        try OnboardingRelationshipValidator.validate(
            in: modelContext,
            failure: .corruptionSuspected
        )

        var preferenceDescriptor = FetchDescriptor<UserPreferencesRecord>()
        preferenceDescriptor.fetchLimit = 2
        var progressDescriptor = FetchDescriptor<OnboardingProgressRecord>()
        progressDescriptor.fetchLimit = 2
        let preferences = try modelContext.fetch(preferenceDescriptor)
        let progressRecords = try modelContext.fetch(progressDescriptor)
        guard preferences.count == 1,
              progressRecords.count == 1,
              let preference = preferences.first,
              let progress = progressRecords.first,
              let step = progress.step else {
            throw AppDataFailure.corruptionSuspected
        }

        var profileDescriptor = FetchDescriptor<HRTProfile>(
            sortBy: [SortDescriptor(\.createdAt)]
        )
        profileDescriptor.fetchLimit = 2
        let profiles = try modelContext.fetch(profileDescriptor)
        guard profiles.count <= 1 else {
            throw AppDataFailure.corruptionSuspected
        }

        let today = try HistoricalTimestamp.captured(
            instant: instant,
            timeZoneIdentifier: displayTimeZoneIdentifier
        ).localDate
        let regimen = try onboardingRegimenSnapshot(
            asOf: today,
            terminalOverlay: terminalOverlay
        )
        return OnboardingSnapshot(
            isCompleted: preference.onboardingCompleted,
            progress: OnboardingProgressSnapshot(
                step: step,
                skippedStartDate: progress.skippedStartDate,
                skippedReminder: progress.skippedReminder,
                skippedCountdown: progress.skippedCountdown,
                completedAt: progress.completedAt,
                updatedAt: progress.updatedAt
            ),
            profile: terminalOverlay.hidesHrtJourney
                ? nil
                : profiles.first.map {
                HRTProfileSnapshot(
                    id: $0.id,
                    startDate: $0.startDate,
                    activePeriodStartDate: $0.activePeriodStartDate,
                    createdAt: $0.createdAt
                )
            },
            hasEligibleRegimen: regimen.hasEligibleRegimen,
            regimenNeedsReview: regimen.needsReview,
            drafts: regimen.drafts,
            reminderOptions: regimen.reminderOptions,
            reminderCoverage:
                try onboardingReminderCoverageSnapshot(),
            countdown: try countdownCurrentSnapshot(
                displayTimeZoneIdentifier:
                    displayTimeZoneIdentifier
            )
        )
    }

    func onboardingProfileSnapshot(
        terminalOverlay: DataControlTerminalOverlay = .empty
    ) throws -> HRTProfileSnapshot? {
        var descriptor = FetchDescriptor<HRTProfile>(
            sortBy: [SortDescriptor(\.createdAt)]
        )
        descriptor.fetchLimit = 2
        let profiles = try modelContext.fetch(descriptor)
        guard profiles.count <= 1 else {
            throw AppDataFailure.corruptionSuspected
        }
        guard !terminalOverlay.hidesHrtJourney else {
            return nil
        }
        return profiles.first.map {
            HRTProfileSnapshot(
                id: $0.id,
                startDate: $0.startDate,
                activePeriodStartDate: $0.activePeriodStartDate,
                createdAt: $0.createdAt
            )
        }
    }

    private func onboardingRegimenSnapshot(
        asOf date: CivilDateFact,
        terminalOverlay: DataControlTerminalOverlay
    ) throws -> (
        hasEligibleRegimen: Bool,
        needsReview: Bool,
        drafts: [OnboardingDraftSnapshot],
        reminderOptions: [OnboardingReminderOption]
    ) {
        var versionDescriptor =
            FetchDescriptor<RegimenPlanVersionRecord>()
        versionDescriptor.fetchLimit = 513
        let fetchedVersions = try modelContext.fetch(versionDescriptor)
        guard fetchedVersions.count <= 512 else {
            throw AppDataFailure.corruptionSuspected
        }
        let hiddenRegimenIDs =
            terminalOverlay.draftRegimenVersionIDs
                .union(
                    terminalOverlay.sealedRegimenVersionIDs
                )
        let versions = fetchedVersions.filter {
            !$0.isArchived
                && !hiddenRegimenIDs.contains($0.id)
        }
        let timeline = versions.compactMap { version -> RegimenTimelineVersion? in
            guard let start = version.effectiveStartDate else { return nil }
            return RegimenTimelineVersion(
                id: version.id,
                start: start,
                end: version.effectiveEndDate,
                editState: version.editState,
                requiresReview: version.requiresMigrationReview
            )
        }
        guard timeline.count == versions.count else {
            throw AppDataFailure.corruptionSuspected
        }
        let projection = RegimenTimelineResolver.project(timeline, asOf: date)
        let eligibleIDs = Set(
            [projection.current?.id].compactMap { $0 }
                + projection.upcoming.map(\.id)
        )
        let hasEligibleRegimen = !projection.isAmbiguous
            && !eligibleIDs.isEmpty

        var itemDescriptor = FetchDescriptor<RegimenItemRecord>()
        itemDescriptor.fetchLimit = 4_097
        let items = try modelContext.fetch(itemDescriptor)
        guard items.count <= 4_096 else {
            throw AppDataFailure.corruptionSuspected
        }
        var scheduleDescriptor = FetchDescriptor<ScheduleRuleRecord>()
        scheduleDescriptor.fetchLimit = 4_097
        let schedules = try modelContext.fetch(scheduleDescriptor)
        guard schedules.count <= 4_096 else {
            throw AppDataFailure.corruptionSuspected
        }
        let scheduleGroups = Dictionary(
            grouping: schedules,
            by: \.regimenItemID
        )
        guard scheduleGroups.values.allSatisfy({ $0.count == 1 }) else {
            throw AppDataFailure.corruptionSuspected
        }

        var preferenceDescriptor =
            FetchDescriptor<ReminderPreferenceRecord>()
        preferenceDescriptor.fetchLimit = 4_097
        let preferences = try modelContext.fetch(preferenceDescriptor)
        guard preferences.count <= 4_096 else {
            throw AppDataFailure.corruptionSuspected
        }
        let preferencesByKey = try AppDataIndex.checkedUniqueMap(
            preferences,
            keyedBy: \.preferenceKey,
            failure: .corruptionSuspected
        )
        let reminderOptions = try items.compactMap {
            item -> OnboardingReminderOption? in
            guard eligibleIDs.contains(item.regimenVersionID),
                  let schedule = scheduleGroups[item.id]?.first,
                  schedule.revision > 0 else {
                return nil
            }
            let preferenceKey = ReminderPreferenceRecord.key(
                scheduleRuleID: schedule.id,
                revision: schedule.revision
            )
            let preference = preferencesByKey[preferenceKey]
            if let preference {
                guard preference.scheduleRuleID == schedule.id,
                      preference.expectedRuleRevision
                        == schedule.revision else {
                    throw AppDataFailure.corruptionSuspected
                }
            }
            return OnboardingReminderOption(
                scheduleRuleID: schedule.id,
                scheduleRevision: schedule.revision,
                regimenVersionID: item.regimenVersionID,
                displayName: item.displayName,
                scheduleSummary: onboardingScheduleSummary(schedule),
                isEnabled: preference?.isEnabled ?? false,
                defaultSnoozeMinutes:
                    preference?.defaultSnoozeMinutes
                        ?? schedule.defaultSnoozeMinutes
            )
        }
        .sorted {
            $0.displayName != $1.displayName
                ? $0.displayName < $1.displayName
                : $0.scheduleRuleID.uuidString
                    < $1.scheduleRuleID.uuidString
        }

        let drafts = versions.compactMap {
            version -> OnboardingDraftSnapshot? in
            guard version.editState == .draft,
                  let start = version.effectiveStartDate else {
                return nil
            }
            return OnboardingDraftSnapshot(
                id: version.id,
                title: version.title,
                effectiveStartDate: start
            )
        }
        .sorted {
            $0.effectiveStartDate != $1.effectiveStartDate
                ? $0.effectiveStartDate > $1.effectiveStartDate
                : $0.id.uuidString < $1.id.uuidString
        }

        return (
            hasEligibleRegimen,
            projection.isAmbiguous
                || versions.contains(where: \.requiresMigrationReview),
            drafts,
            reminderOptions
        )
    }

    private func onboardingScheduleSummary(
        _ schedule: ScheduleRuleRecord
    ) -> String {
        switch schedule.kind {
        case .dailyTimes:
            schedule.localTimes.isEmpty
                ? "每日"
                : "每日 \(schedule.localTimes)"
        case .weekly:
            schedule.weekdays.isEmpty
                ? "每周"
                : "每周 \(schedule.weekdays)"
        case .everyNDays:
            schedule.intervalDays.map { "每 \($0) 天" } ?? "按间隔"
        case .oneOff:
            "单次安排"
        }
    }

    private func onboardingReminderCoverageSnapshot()
        throws -> NotificationCoverageSnapshot {
        var descriptor = FetchDescriptor<NotificationCoverageRecord>()
        descriptor.fetchLimit = 2
        let records = try modelContext.fetch(descriptor)
        guard records.count == 1,
              let record = records.first,
              let status = record.status else {
            throw AppDataFailure.corruptionSuspected
        }
        return NotificationCoverageSnapshot(
            status: status,
            scheduledThrough: record.scheduledThrough,
            desiredCount: record.desiredCount,
            confirmedPendingCount: record.confirmedPendingCount,
            lastErrorCode: record.lastErrorCode,
            observedAt: record.observedAt
        )
    }
}
