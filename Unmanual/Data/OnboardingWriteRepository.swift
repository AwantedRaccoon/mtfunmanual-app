import Foundation
import SwiftData

enum OnboardingProgressAction: Equatable, Sendable {
    case reviewPrivacy
    case continueStartDate(skipped: Bool)
    case continueRegimen
    case continueReminder(skipped: Bool)
    case continueCountdown(skipped: Bool)
    case reopen(OnboardingStep)
    case moveBack
}

struct UpdateOnboardingProgressCommand: Sendable {
    let expectedStep: OnboardingStep
    let action: OnboardingProgressAction
    let committedAt: Date

    init(
        expectedStep: OnboardingStep,
        action: OnboardingProgressAction,
        committedAt: Date = Date()
    ) {
        self.expectedStep = expectedStep
        self.action = action
        self.committedAt = committedAt
    }
}

struct OnboardingProgressResult: Equatable, Sendable {
    let step: OnboardingStep
    let didApply: Bool
}

struct CompleteOnboardingCommand: Sendable {
    let committedAt: Date

    init(committedAt: Date = Date()) {
        self.committedAt = committedAt
    }
}

struct CompleteOnboardingResult: Equatable, Sendable {
    let didApply: Bool
}

extension AppWriteActor {
    func updateOnboardingProgress(
        _ command: UpdateOnboardingProgressCommand,
        failureInjection: AppWriteFailureInjection? = nil
    ) throws -> OnboardingProgressResult {
        guard command.committedAt.timeIntervalSince1970.isFinite,
              command.expectedStep != .completed else {
            throw AppWriteFailure.invalidInput
        }
        let progress = try requiredOnboardingProgress()
        guard progress.step == command.expectedStep else {
            throw AppWriteFailure.staleRecord
        }
        let target = try onboardingTargetStep(
            for: command.action,
            current: command.expectedStep,
            committedAt: command.committedAt
        )
        if target == command.expectedStep {
            return OnboardingProgressResult(
                step: target,
                didApply: false
            )
        }

        modelContext.autosaveEnabled = false
        do {
            try modelContext.transaction {
                guard progress.step == command.expectedStep else {
                    throw AppWriteFailure.staleRecord
                }
                let reservation = try reserveRevisionInCurrentTransaction(
                    committedAt: command.committedAt
                )
                progress.stepRawValue = target.rawValue
                switch command.action {
                case let .continueStartDate(skipped):
                    progress.skippedStartDate = skipped
                case let .continueReminder(skipped):
                    progress.skippedReminder = skipped
                case let .continueCountdown(skipped):
                    progress.skippedCountdown = skipped
                case .reopen(.startDate):
                    progress.skippedStartDate = false
                case .reopen(.reminder):
                    progress.skippedReminder = false
                case .reopen(.countdown):
                    progress.skippedCountdown = false
                case .reviewPrivacy, .continueRegimen, .reopen, .moveBack:
                    break
                }
                progress.updatedAt = command.committedAt
                if failureInjection == .beforeRevisionCommit {
                    throw AppWriteFailure.injected
                }
                try upsertRevision(
                    recordType: "OnboardingProgressRecord",
                    recordID: CoreTimeRegimenBackfill.stableUUID(
                        for: progress.singletonKey
                    ),
                    fields: try OnboardingDigestV1.progress(progress),
                    reservation: reservation,
                    committedAt: command.committedAt
                )
                try markCommitted(at: command.committedAt)
            }
            return OnboardingProgressResult(
                step: target,
                didApply: true
            )
        } catch {
            modelContext.rollback()
            throw error
        }
    }

    func completeOnboarding(
        _ command: CompleteOnboardingCommand,
        failureInjection: AppWriteFailureInjection? = nil
    ) throws -> CompleteOnboardingResult {
        guard command.committedAt.timeIntervalSince1970.isFinite else {
            throw AppWriteFailure.invalidInput
        }
        let progress = try requiredOnboardingProgress()
        let preference = try requiredOnboardingPreference()
        if progress.step == .completed,
           preference.onboardingCompleted {
            return CompleteOnboardingResult(didApply: false)
        }
        guard progress.step == .ready,
              !preference.onboardingCompleted,
              try hasEligibleOnboardingRegimen(at: command.committedAt) else {
            throw AppWriteFailure.staleRecord
        }

        modelContext.autosaveEnabled = false
        do {
            try modelContext.transaction {
                guard progress.step == .ready,
                      !preference.onboardingCompleted,
                      try hasEligibleOnboardingRegimen(
                          at: command.committedAt
                      ) else {
                    throw AppWriteFailure.staleRecord
                }
                let reservation = try reserveRevisionInCurrentTransaction(
                    committedAt: command.committedAt
                )
                progress.stepRawValue = OnboardingStep.completed.rawValue
                progress.completedAt = command.committedAt
                progress.updatedAt = command.committedAt
                preference.onboardingCompleted = true
                if failureInjection == .beforeRevisionCommit {
                    throw AppWriteFailure.injected
                }
                try upsertRevision(
                    recordType: "OnboardingProgressRecord",
                    recordID: CoreTimeRegimenBackfill.stableUUID(
                        for: progress.singletonKey
                    ),
                    fields: try OnboardingDigestV1.progress(progress),
                    reservation: reservation,
                    committedAt: command.committedAt
                )
                try upsertRevision(
                    recordType: "UserPreferencesRecord",
                    recordID: CoreTimeRegimenBackfill.stableUUID(
                        for: preference.singletonKey
                    ),
                    fields: CoreFactDigestV1.preferences(preference),
                    reservation: reservation,
                    committedAt: command.committedAt
                )
                try markCommitted(at: command.committedAt)
            }
            return CompleteOnboardingResult(didApply: true)
        } catch {
            modelContext.rollback()
            throw error
        }
    }

    private func onboardingTargetStep(
        for action: OnboardingProgressAction,
        current: OnboardingStep,
        committedAt: Date
    ) throws -> OnboardingStep {
        switch (current, action) {
        case (.privacy, .reviewPrivacy):
            return .startDate
        case let (.startDate, .continueStartDate(skipped)):
            if !skipped {
                var descriptor = FetchDescriptor<HRTProfile>()
                descriptor.fetchLimit = 2
                let profiles = try modelContext.fetch(descriptor)
                guard profiles.count == 1 else {
                    throw AppWriteFailure.staleRecord
                }
            }
            return .regimen
        case (.regimen, .continueRegimen):
            guard try hasEligibleOnboardingRegimen(
                at: committedAt
            ) else {
                throw AppWriteFailure.staleRecord
            }
            return .reminder
        case let (.reminder, .continueReminder(skipped)):
            if !skipped {
                guard try hasEnabledOnboardingReminder(
                    at: committedAt
                ) else {
                    throw AppWriteFailure.staleRecord
                }
            }
            return .countdown
        case let (.countdown, .continueCountdown(skipped)):
            if !skipped {
                guard try hasActiveOnboardingCountdown() else {
                    throw AppWriteFailure.staleRecord
                }
            }
            return .ready
        case (.startDate, .moveBack):
            return .privacy
        case (.regimen, .moveBack):
            return .startDate
        case (.reminder, .moveBack):
            return .regimen
        case (.countdown, .moveBack):
            return .reminder
        case (.ready, .moveBack):
            return .countdown
        case let (.ready, .reopen(step))
            where [
                OnboardingStep.startDate,
                .regimen,
                .reminder,
                .countdown,
            ].contains(step):
            return step
        default:
            throw AppWriteFailure.staleRecord
        }
    }

    private func requiredOnboardingProgress()
        throws -> OnboardingProgressRecord {
        var descriptor = FetchDescriptor<OnboardingProgressRecord>()
        descriptor.fetchLimit = 2
        let values = try modelContext.fetch(descriptor)
        guard values.count == 1,
              let progress = values.first,
              OnboardingRelationshipValidator.validates(progress) else {
            throw AppWriteFailure.missingFoundation
        }
        return progress
    }

    private func requiredOnboardingPreference()
        throws -> UserPreferencesRecord {
        var descriptor = FetchDescriptor<UserPreferencesRecord>()
        descriptor.fetchLimit = 2
        let values = try modelContext.fetch(descriptor)
        guard values.count == 1, let preference = values.first else {
            throw AppWriteFailure.missingFoundation
        }
        return preference
    }

    private func hasEligibleOnboardingRegimen(
        at instant: Date
    ) throws -> Bool {
        try !eligibleOnboardingRegimenIDs(at: instant).isEmpty
    }

    private func eligibleOnboardingRegimenIDs(
        at instant: Date
    ) throws -> Set<UUID> {
        let today = try HistoricalTimestamp.captured(
            instant: instant,
            timeZoneIdentifier: TimeZone.autoupdatingCurrent.identifier
        ).localDate
        var descriptor = FetchDescriptor<RegimenPlanVersionRecord>()
        descriptor.fetchLimit = 513
        let records = try modelContext.fetch(descriptor)
        guard records.count <= 512 else {
            throw AppWriteFailure.staleRecord
        }
        let timeline = records.compactMap {
            record -> RegimenTimelineVersion? in
            guard !record.isArchived,
                  let start = record.effectiveStartDate else {
                return nil
            }
            return RegimenTimelineVersion(
                id: record.id,
                start: start,
                end: record.effectiveEndDate,
                editState: record.editState,
                requiresReview: record.requiresMigrationReview
            )
        }
        let expectedCount = records.filter { !$0.isArchived }.count
        guard timeline.count == expectedCount else {
            throw AppWriteFailure.staleRecord
        }
        let projection = RegimenTimelineResolver.project(
            timeline,
            asOf: today
        )
        guard !projection.isAmbiguous else { return [] }
        return Set(
            [projection.current?.id].compactMap { $0 }
                + projection.upcoming.map(\.id)
        )
    }

    private func hasEnabledOnboardingReminder(
        at instant: Date
    ) throws -> Bool {
        let eligibleVersionIDs = try eligibleOnboardingRegimenIDs(
            at: instant
        )
        guard !eligibleVersionIDs.isEmpty else { return false }
        var itemDescriptor = FetchDescriptor<RegimenItemRecord>()
        itemDescriptor.fetchLimit = 4_097
        let items = try modelContext.fetch(itemDescriptor)
        guard items.count <= 4_096 else {
            throw AppWriteFailure.staleRecord
        }
        let eligibleItemIDs = Set(
            items.filter {
                eligibleVersionIDs.contains($0.regimenVersionID)
            }.map(\.id)
        )
        var scheduleDescriptor = FetchDescriptor<ScheduleRuleRecord>()
        scheduleDescriptor.fetchLimit = 4_097
        let schedules = try modelContext.fetch(scheduleDescriptor)
        guard schedules.count <= 4_096 else {
            throw AppWriteFailure.staleRecord
        }
        let eligibleKeys = Set(
            schedules.compactMap { schedule -> String? in
                guard eligibleItemIDs.contains(schedule.regimenItemID) else {
                    return nil
                }
                return ReminderPreferenceRecord.key(
                    scheduleRuleID: schedule.id,
                    revision: schedule.revision
                )
            }
        )
        let enabled = true
        var descriptor = FetchDescriptor<ReminderPreferenceRecord>(
            predicate: #Predicate { $0.isEnabled == enabled }
        )
        descriptor.fetchLimit = 4_097
        let preferences = try modelContext.fetch(descriptor)
        guard preferences.count <= 4_096 else {
            throw AppWriteFailure.staleRecord
        }
        return preferences.contains {
            eligibleKeys.contains($0.preferenceKey)
        }
    }

    private func hasActiveOnboardingCountdown() throws -> Bool {
        let active = CountdownLifecycle.active.rawValue
        var descriptor = FetchDescriptor<CountdownStateRecord>(
            predicate: #Predicate {
                $0.lifecycleRawValue == active && !$0.requiresReview
            }
        )
        descriptor.fetchLimit = 2
        let values = try modelContext.fetch(descriptor)
        guard values.count <= 1 else {
            throw AppWriteFailure.staleRecord
        }
        return values.count == 1
    }
}
